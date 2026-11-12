#!/usr/bin/env python3
"""Kubernetes Ingresses (written for ingress-nginx) -> Istio VirtualServices on one Gateway (ingress-to-istio.sh).

The Ingress objects stay the source: charts keep creating them, this converts them (re-runnable). One
VirtualService per host (paths of every Ingress of that host), routes ordered like ingress-nginx (exact, then the
longest literal prefix first, "/" last).

ingress-nginx behaviour that is converted
  paths            Exact -> exact; Prefix -> exact + "<path>/" prefix (element-wise like Kubernetes);
                   ImplementationSpecific -> prefix
  regex paths      (use-regex / rewrite-target): simple forms become a prefix (+ prefix rewrite), checked by
  + rewrite-target simulating nginx's rewrite on sample URIs; anything else becomes an RE2 regex match with
                   uriRegexRewrite (nginx: case-insensitive, here case-sensitive)
  app-root         redirect of "/" to the app root
  proxy-read/send-timeout   route timeout (the larger one)
  backend-protocol HTTPS / GRPCS    DestinationRule tls SIMPLE (no verification, like ingress-nginx)
  affinity: cookie DestinationRule consistentHash httpCookie (session-cookie-name / -max-age)
  body size, buffering, buffer sizes, ssl-redirect   nothing to do (Envoy streams; the Gateway redirects to https)
Reported, not converted: auth-*, whitelist-source-range, *-snippet, canary*, limit-*, enable-cors,
  permanent/temporal-redirect, custom-http-errors, ... (see the report)

Usage: ingress_to_istio.py --gateway istio-system/cp-gateway [--api networking.istio.io/v1] [--class nginx ...]
       [--namespace ns ...] < {"ingresses": <kubectl get ingress -A -o json>, "services": <... svc -A>,
                               "virtualservices": <... virtualservices -A>}
Output: JSON {"objects": [...], "report": [...], "hosts": [...]}
"""
import argparse
import json
import re
import sys

A = "nginx.ingress.kubernetes.io/"
MANAGED = "app.kubernetes.io/managed-by"
MANAGER = "ingress-to-istio"
HANDLED = {"rewrite-target", "use-regex", "app-root", "proxy-read-timeout", "proxy-send-timeout",
           "proxy-connect-timeout", "backend-protocol", "affinity", "affinity-mode", "session-cookie-name",
           "session-cookie-max-age", "session-cookie-expires", "session-cookie-path", "proxy-body-size",
           "proxy-buffering", "proxy-request-buffering", "proxy-buffer-size", "proxy-buffers-number",
           "client-body-buffer-size", "ssl-redirect", "force-ssl-redirect", "proxy-http-version",
           "large-client-header-buffers", "ssl-passthrough"}
META = set("()[]{}*+?.\\$^|")


def literal_prefix(pattern):
    out = []
    for ch in pattern:
        if ch in META:
            break
        out.append(ch)
    return "".join(out)


def nginx_target(target):
    """$1 -> \\g<1> (Python re.sub)"""
    return re.sub(r"\$(\d+)", r"\\g<\1>", target)


def regex_route(path, target):
    """Route for an ingress-nginx regex location (^<path>, case-insensitive) with an optional rewrite-target.
    Returns (match, rewrite): match {"prefix"|"regex": ...}, rewrite {"uri": ...} / {"uriRegexRewrite": ...} / None."""
    try:
        rx = re.compile(path, re.I)
    except re.error:
        return None, None
    # literal start of the location, also through groups: /(cpmigui/.*) -> /cpmigui/ (checked on samples below)
    lit = literal_prefix(path.replace("(", "").replace(")", "")) or "/"
    samples = ["", "a", "a/b", "x.y-z/1", "q/"]
    uris = [lit + s for s in samples]
    narrower = len(lit) > 1 and rx.match(lit[:-1] + "\x01")         # the pattern also takes shorter paths
    if not narrower and all(rx.match(u) for u in uris):
        if not target:
            return {"prefix": lit}, None                            # /foo(.*), /foo.*: a prefix location
        outs = [rx.sub(nginx_target(target), u, count=1) for u in uris]
        rests = [u[len(lit):] for u in uris]
        if all(o.endswith(r) for o, r in zip(outs, rests)):
            heads = {o[:len(o) - len(r)] for o, r in zip(outs, rests)}
            if len(heads) == 1:
                head = heads.pop()
                if head == lit:
                    return {"prefix": lit}, None                    # identity: /(.*) -> /$1, /(x/.*) -> /$1
                if head:
                    return {"prefix": lit}, {"uri": head}           # /cpapi/(.*) -> /$1: prefix rewrite
    # general case: RE2 regex (full match of the path) + regex rewrite
    match = {"regex": path + ("" if path.endswith("$") else ".*")}
    if not target:
        return match, None
    return match, {"uriRegexRewrite": {"match": "^" + path, "rewrite": re.sub(r"\$(\d+)", r"\\\1", target)}}


def to_seconds(value):
    m = re.match(r"^\s*(\d+)\s*(s|m)?\s*$", str(value or ""))
    if not m:
        return 0
    return int(m.group(1)) * (60 if m.group(2) == "m" else 1)


def svc_port(services, ns, name, port):
    if "number" in port:
        return port["number"]
    svc = services.get((ns, name))
    if not svc:
        return None
    ports = (svc.get("spec") or {}).get("ports") or []
    for p in ports:
        if p.get("name") == port.get("name"):
            return p["port"]
    return ports[0]["port"] if len(ports) == 1 else None


def convert(ingresses, services, virtualservices, gateway, api="networking.istio.io/v1", classes=(), namespaces=()):
    svc = {(s["metadata"]["namespace"], s["metadata"]["name"]): s for s in services.get("items", [])}
    report = []
    taken = {}                                    # host -> ns/name of a VirtualService not made by this tool
    for vs in virtualservices.get("items", []):
        if ((vs["metadata"].get("labels") or {}).get(MANAGED)) == MANAGER:
            continue
        for h in (vs.get("spec") or {}).get("hosts") or []:
            taken[h] = f"{vs['metadata']['namespace']}/{vs['metadata']['name']}"
    hosts = {}                                    # host -> {"ns": ..., "routes": [...], "sources": set()}
    rules_dr = {}                                 # destination host -> DestinationRule trafficPolicy
    for ing in ingresses.get("items", []):
        meta, spec = ing["metadata"], ing.get("spec") or {}
        ns, name = meta["namespace"], meta["name"]
        cls = spec.get("ingressClassName") or (meta.get("annotations") or {}).get("kubernetes.io/ingress.class", "")
        if classes and cls not in classes:
            continue
        if namespaces and ns not in namespaces:
            continue
        ann = {k[len(A):]: v for k, v in (meta.get("annotations") or {}).items() if k.startswith(A)}
        for k in sorted(set(ann) - HANDLED):
            report.append(f"[WARN] {ns}/{name}: annotation {A}{k} is not converted - check it by hand")
        target = ann.get("rewrite-target", "")
        regex = ann.get("use-regex") == "true" or "$" in target or bool(target)
        timeout = max(to_seconds(ann.get("proxy-read-timeout")), to_seconds(ann.get("proxy-send-timeout")))
        proto = (ann.get("backend-protocol") or "").upper()
        if spec.get("defaultBackend"):
            report.append(f"[WARN] {ns}/{name}: defaultBackend is not converted (no host)")
        for rule in spec.get("rules") or []:
            host = rule.get("host")
            if not host:
                report.append(f"[WARN] {ns}/{name}: rule without host is not converted")
                continue
            if host in taken:
                report.append(f"[INFO] {host}: VirtualService {taken[host]} exists (not made by this tool) - kept")
                continue
            h = hosts.setdefault(host, {"ns": ns, "routes": [], "sources": set()})
            h["sources"].add(f"{ns}/{name}")
            if ann.get("app-root"):
                h["routes"].append({"order": (0, 0), "match": [{"uri": {"exact": "/"}}],
                                    "redirect": {"uri": ann["app-root"]}})
            for p in (rule.get("http") or {}).get("paths") or []:
                backend = (p.get("backend") or {}).get("service")
                if not backend:
                    report.append(f"[WARN] {ns}/{name}: {host}{p.get('path', '/')} has no service backend - skipped")
                    continue
                port = svc_port(svc, ns, backend["name"], backend.get("port") or {})
                dest = f"{backend['name']}.{ns}.svc.cluster.local"
                destination = {"host": dest, **({"port": {"number": port}} if port else {})}
                if port is None:
                    report.append(f"[WARN] {ns}/{name}: port {backend.get('port')} of service {backend['name']} not "
                                  "resolved - the service must have one port")
                path = p.get("path") or "/"
                ptype = p.get("pathType", "ImplementationSpecific")
                rewrite = None
                if regex:
                    match, rewrite = regex_route(path, target)
                    if match is None:
                        report.append(f"[WARN] {ns}/{name}: path regex {path!r} is not valid - skipped")
                        continue
                    matches = [{"uri": match}]
                    lit = match.get("prefix") or literal_prefix(path.replace("(", "").replace(")", ""))
                    order = (1, -len(lit))
                    if "regex" in match:
                        report.append(f"[INFO] {host}{path}: regex route {match['regex']!r}"
                                      + (f" rewrite {rewrite}" if rewrite else ""))
                elif ptype == "Exact":
                    matches, order = [{"uri": {"exact": path}}], (0, -len(path))
                elif ptype == "Prefix" and path != "/":
                    base = path.rstrip("/")
                    matches, order = [{"uri": {"exact": base}}, {"uri": {"prefix": base + "/"}}], (1, -len(base))
                else:
                    matches, order = [{"uri": {"prefix": path}}], (1, -len(path))
                route = {"order": order, "match": matches, "route": [{"destination": destination}]}
                if rewrite:
                    route["rewrite"] = rewrite
                if timeout:
                    route["timeout"] = f"{timeout}s"
                h["routes"].append(route)
                policy = {}
                if proto in ("HTTPS", "GRPCS"):
                    policy["tls"] = {"mode": "SIMPLE", "insecureSkipVerify": True}
                if ann.get("affinity") == "cookie":
                    policy["loadBalancer"] = {"consistentHash": {"httpCookie": {
                        "name": ann.get("session-cookie-name") or "INGRESSCOOKIE",
                        "ttl": f"{to_seconds(ann.get('session-cookie-max-age')) or 3600}s"}}}
                if policy:
                    rules_dr[dest] = (ns, backend["name"], policy)
    objects = []
    for host, h in sorted(hosts.items()):
        routes = sorted(h["routes"], key=lambda r: r["order"])
        seen, http = set(), []
        for r in routes:
            key = json.dumps(r["match"], sort_keys=True)
            if key in seen:
                report.append(f"[WARN] {host}: duplicate path {key} - the first Ingress wins")
                continue
            seen.add(key)
            http.append({k: v for k, v in r.items() if k != "order"})
        objects.append({
            "apiVersion": api, "kind": "VirtualService",
            "metadata": {"name": re.sub(r"[^a-z0-9-]", "-", host.lower())[:63].strip("-"), "namespace": h["ns"],
                         "labels": {MANAGED: MANAGER},
                         "annotations": {"ingress-to-istio/sources": ",".join(sorted(h["sources"]))}},
            "spec": {"hosts": [host], "gateways": [gateway], "http": http}})
    for dest, (ns, name, policy) in sorted(rules_dr.items()):
        objects.append({"apiVersion": api, "kind": "DestinationRule",
                        "metadata": {"name": f"{name}-ingress", "namespace": ns, "labels": {MANAGED: MANAGER}},
                        "spec": {"host": dest, "trafficPolicy": policy}})
    return {"objects": objects, "report": report, "hosts": sorted(hosts)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gateway", required=True)
    ap.add_argument("--api", default="networking.istio.io/v1")
    ap.add_argument("--class", dest="classes", action="append", default=[])
    ap.add_argument("--namespace", dest="namespaces", action="append", default=[])
    a = ap.parse_args()
    data = json.load(sys.stdin)
    print(json.dumps(convert(data.get("ingresses") or {}, data.get("services") or {}, data.get("virtualservices") or {},
                             a.gateway, a.api, a.classes, a.namespaces)))


if __name__ == "__main__":
    main()
