#!/usr/bin/env python3
"""Cluster checks of ./deploy-cicd-portal.sh preflight that matter on RKE2 (and on any cluster):

  distro      Kubernetes distribution from the kubelet version (RKE2: v1.30.4+rke2r1)
  ingress     which ingress-nginx controllers serve the IngressClass of the portal; two controllers claiming it
              (RKE2's rke2-ingress-nginx + a separately installed ingress-nginx) and whether the DNS address of
              the platform (keycloak.<domain>) reaches a controller of that class
  psa         Pod Security: would a root pod (kaniko, build images, GitLab omnibus) be admitted in the CI
              namespaces? (server-side dry-run; RKE2 "profile: cis" makes "restricted" the cluster default)
  harbor-pull can every node pull from Harbor? (one short-lived probe pod per node with an image of Harbor
              that already runs in the cluster; RKE2's embedded containerd does not use the restart that
              K-PaaS cp-cert-setup does for the CA)
Output lines: [OK] / [WARN] / [FAIL]; exit 1 when a check failed.

Usage: cluster_check.py <check|all> [--ingress-class nginx] [--host keycloak.<domain>]
       [--namespaces cicd-jenkins,cicd-runner] [--pod-security baseline] [--harbor-host harbor.<domain>]
       [--no-pull] [--timeout 120]
"""
import argparse
import json
import re
import socket
import subprocess
import sys
import time

FAILED = []
RKE2_KUBECTL = "/var/lib/rancher/rke2/bin/kubectl"


def say(level, msg):
    print({"OK": "[OK]   ", "WARN": "[WARN] ", "FAIL": "[FAIL] "}[level] + msg)
    if level == "FAIL":
        FAILED.append(msg)


def kubectl(*args, stdin=None, check=True):
    r = subprocess.run(["kubectl", *args], input=stdin, capture_output=True, text=True, timeout=120)
    if check and r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or f"kubectl {' '.join(args)} failed")
    return r


def get(*args):
    r = kubectl("get", *args, "-o", "json", check=False)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else {"items": []}


# ------------------------------------------------------------------------------------------------ distro ---
def distro(nodes):
    versions = {n["status"]["nodeInfo"]["kubeletVersion"] for n in nodes["items"]}
    joined = " ".join(sorted(versions))
    if "+rke2" in joined:
        return "rke2", joined
    if "+k3s" in joined:
        return "k3s", joined
    return "kubernetes", joined


# ----------------------------------------------------------------------------------------------- ingress ---
CONTROLLER_RE = re.compile(r"nginx-ingress-controller|ingress-nginx/controller")


def _arg(args, name, default):
    for a in args:
        if a.startswith(f"--{name}="):
            return a.split("=", 1)[1]
    return default


def controllers(pods, services):
    """ingress-nginx controllers: {(namespace, owner): {class, controller_class, ips}}"""
    found = {}
    for p in pods["items"]:
        if (p.get("status") or {}).get("phase") != "Running":
            continue
        spec = p["spec"]
        for c in spec.get("containers", []):
            args = (c.get("command") or []) + (c.get("args") or [])
            if not (CONTROLLER_RE.search(c.get("image", "")) or any("nginx-ingress-controller" in a for a in args)):
                continue
            meta = p["metadata"]
            ref = next(iter(meta.get("ownerReferences") or []), {})
            owner = ref.get("name", meta["name"])
            if ref.get("kind") == "ReplicaSet":
                owner = owner.rsplit("-", 1)[0]          # Deployment name
            key = (meta["namespace"], owner)
            entry = found.setdefault(key, {"class": _arg(args, "ingress-class", "nginx"),
                                           "controller_class": _arg(args, "controller-class", "k8s.io/ingress-nginx"),
                                           "ips": set(), "host_network": False})
            host_ports = any(pt.get("hostPort") in (80, 443) for pt in c.get("ports") or [])
            if spec.get("hostNetwork") or host_ports:
                entry["host_network"] = True
                if p["status"].get("hostIP"):
                    entry["ips"].add(p["status"]["hostIP"])
    for s in services["items"]:
        if s["spec"].get("type") != "LoadBalancer":
            continue
        ns = s["metadata"]["namespace"]
        for (cns, owner), entry in found.items():
            if cns == ns and ("controller" in s["metadata"]["name"] or "ingress" in s["metadata"]["name"]):
                for i in (s.get("status") or {}).get("loadBalancer", {}).get("ingress") or []:
                    if i.get("ip"):
                        entry["ips"].add(i["ip"])
                entry["ips"].update(s["spec"].get("externalIPs") or [])
    return found


def check_ingress(ingress_class, host, classes, pods, services, resolve=None):
    resolve = resolve or (lambda h: sorted({a[4][0] for a in socket.getaddrinfo(h, 443, socket.AF_INET)}))
    ctrls = controllers(pods, services)
    by_name = {c["metadata"]["name"]: c for c in classes["items"]}
    if ingress_class not in by_name:
        say("FAIL", f"IngressClass {ingress_class} not found (cp-portal-vars.sh INGRESS_CLASS_NAME)")
        return
    wanted = by_name[ingress_class]["spec"].get("controller", "")
    serving = {k: v for k, v in ctrls.items() if v["controller_class"] == wanted}
    if not ctrls:
        say("WARN", "no running ingress-nginx controller found (another ingress controller? not checked)")
        return
    for (ns, name), v in sorted(ctrls.items()):
        say("OK", f"ingress controller {ns}/{name}: class {v['class']} ({v['controller_class']}), "
                  f"{'host network' if v['host_network'] else 'service'} {', '.join(sorted(v['ips'])) or '-'}")
    if not serving:
        say("FAIL", f"no controller serves IngressClass {ingress_class} (controller {wanted})")
        return
    if len(serving) > 1:
        names = ", ".join(f"{ns}/{n}" for ns, n in sorted(serving))
        say("WARN", f"{len(serving)} controllers claim IngressClass {ingress_class}: {names} - they fight over the "
                    "Ingress status; RKE2: keep one (disable rke2-ingress-nginx in /etc/rancher/rke2/config.yaml "
                    "'disable: [rke2-ingress-nginx]', or give the other controller its own class)")
    if not host:
        return
    try:
        ips = resolve(host)
    except OSError as e:
        say("FAIL", f"DNS: {host} does not resolve ({e})")
        return
    reached = {k for k, v in ctrls.items() if v["ips"] & set(ips)}
    if not reached:
        say("WARN", f"DNS: {host} -> {', '.join(ips)} is no controller address (an external load balancer / VIP in "
                    "front? then make sure it forwards to the controller of the portal's IngressClass)")
    elif not reached & set(serving):
        names = ", ".join(f"{ns}/{n}" for ns, n in sorted(reached))
        say("FAIL", f"DNS: {host} -> {', '.join(ips)} reaches {names}, which does not serve IngressClass "
                    f"{ingress_class}: the portal's Ingresses would not answer there")
    else:
        say("OK", f"DNS: {host} -> {', '.join(ips)} (controller of IngressClass {ingress_class})")


# --------------------------------------------------------------------------------------------------- psa ---
PSA_LABEL = "pod-security.kubernetes.io/enforce"


def root_pod(ns):
    return json.dumps({"apiVersion": "v1", "kind": "Pod",
                       "metadata": {"name": "cicd-preflight-psa", "namespace": ns},
                       "spec": {"containers": [{"name": "c", "image": "busybox:1.36",
                                                "securityContext": {"runAsUser": 0}}]}})


def root_admitted(ns):
    """None when the namespace does not exist; else (admitted, message)"""
    r = kubectl("apply", "--dry-run=server", "-f", "-", stdin=root_pod(ns), check=False)
    err = r.stderr.strip()
    if r.returncode == 0:
        return True, ""
    if "not found" in err and "namespace" in err.lower():
        return None
    return False, err.splitlines()[-1][:300] if err else "rejected"


def check_psa(namespaces, level, admitted=root_admitted, labels=None):
    if labels is None:
        labels = {n["metadata"]["name"]: n["metadata"].get("labels") or {} for n in get("namespaces")["items"]}
    default_ok = None
    for ns in namespaces:
        if ns not in labels:
            continue
        res = admitted(ns)
        if res is None:
            continue
        ok, msg = res
        enforce = labels[ns].get(PSA_LABEL, "")
        if ok:
            say("OK", f"Pod Security {ns}: root build pods admitted ({enforce or 'cluster default'})")
        elif enforce:
            say("FAIL", f"Pod Security {ns}: enforce={enforce} rejects root build pods (kaniko, build images, "
                        f"GitLab): kubectl label ns {ns} {PSA_LABEL}=baseline --overwrite")
        elif level:
            say("OK", f"Pod Security {ns}: cluster default rejects root pods - the install labels it "
                      f"{PSA_LABEL}={level} (CICD_POD_SECURITY)")
        else:
            say("FAIL", f"Pod Security {ns}: cluster default rejects root build pods and CICD_POD_SECURITY is empty")
    missing = [ns for ns in namespaces if ns not in labels]
    if missing:
        # not created yet: what does the cluster default do? (probe in "default" when it has no own label)
        if PSA_LABEL not in labels.get("default", {PSA_LABEL: "x"}):
            res = admitted("default")
            default_ok = res[0] if res else None
        if default_ok is False and not level:
            say("FAIL", f"Pod Security: the cluster default rejects root pods (RKE2 profile: cis?) and "
                        f"CICD_POD_SECURITY is empty - {', '.join(missing)} would reject the builds")
        elif default_ok is False:
            say("OK", f"Pod Security: cluster default is restrictive - {', '.join(missing)} will be labeled "
                      f"{PSA_LABEL}={level} when created (CICD_POD_SECURITY)")
        else:
            say("OK", f"Pod Security: {', '.join(missing)} not created yet; the cluster default admits root pods"
                      + (f" (they are labeled {level})" if level else ""))


# ------------------------------------------------------------------------------------------- harbor-pull ---
def harbor_image(pods, harbor_host):
    """(namespace, image, pull secrets) of a running pod with an image of Harbor"""
    for p in pods["items"]:
        if (p.get("status") or {}).get("phase") != "Running":
            continue
        for c in p["spec"].get("containers", []):
            if c.get("image", "").startswith(harbor_host + "/"):
                return p["metadata"]["namespace"], c["image"], p["spec"].get("imagePullSecrets") or []
    return None


def probe_pod(name, ns, node, image, secrets):
    return {"apiVersion": "v1", "kind": "Pod",
            "metadata": {"name": name, "namespace": ns, "labels": {"app.kubernetes.io/part-of": "cicd-preflight"}},
            "spec": {"nodeName": node, "restartPolicy": "Never", "imagePullSecrets": secrets,
                     "tolerations": [{"operator": "Exists"}], "automountServiceAccountToken": False,
                     "securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
                     "containers": [{"name": "pull", "image": image, "imagePullPolicy": "Always",
                                     "command": ["/bin/sh", "-c", "exit 0"],
                                     "resources": {"requests": {"cpu": "1m", "memory": "8Mi"}, "limits": {"memory": "32Mi"}},
                                     "securityContext": {"allowPrivilegeEscalation": False,
                                                         "capabilities": {"drop": ["ALL"]}}}]}}


def pull_result(pod):
    """'ok' (image pulled), 'pending', or ('fail', message)"""
    for cs in (pod.get("status") or {}).get("containerStatuses") or []:
        if cs.get("imageID"):
            return "ok"
        waiting = (cs.get("state") or {}).get("waiting") or {}
        if waiting.get("reason") in ("ErrImagePull", "ImagePullBackOff", "InvalidImageName"):
            return ("fail", waiting.get("message", waiting["reason"]))
        if waiting.get("reason") in ("CreateContainerConfigError", "CreateContainerError", "RunContainerError"):
            return "ok"     # the image is there; it only did not start (non-root user, no /bin/sh)
        if (cs.get("state") or {}).get("terminated") or (cs.get("state") or {}).get("running"):
            return "ok"
    return "pending"


def blocking_taints(node):
    """Taints that keep ordinary pods (builds, applications) off a node, e.g. control-plane NoSchedule."""
    return [f"{t['key']}:{t['effect']}" for t in node["spec"].get("taints") or []
            if t.get("effect") in ("NoSchedule", "NoExecute")]


def pull_error(ns, pod):
    """The kubelet's reason of the failed pull (events "Failed to pull image ..."), '' if none."""
    r = kubectl("get", "events", "-n", ns, "--field-selector", f"involvedObject.name={pod}", "-o", "json", check=False)
    if r.returncode != 0:
        return ""
    msgs = [e.get("message", "") for e in json.loads(r.stdout).get("items", [])
            if e.get("reason") == "Failed" and "Back-off" not in e.get("message", "")]
    detailed = [m for m in msgs if re.search(r"x509|certificate|lookup|no such host|unauthorized|denied|"
                                             r"connection refused|i/o timeout|not found|rpc error", m, re.I)]
    return (detailed or msgs or [""])[-1]


def check_harbor_pull(harbor_host, timeout, rke2):
    pods = get("pods", "-A")
    found = harbor_image(pods, harbor_host)
    if not found:
        say("WARN", f"no running pod uses an image of {harbor_host}: node pulls from Harbor not checked")
        return
    ns, image, secrets = found
    node_items = [n for n in get("nodes")["items"] if not n["spec"].get("unschedulable")]
    nodes = [n["metadata"]["name"] for n in node_items]
    tainted = {n["metadata"]["name"]: blocking_taints(n) for n in node_items}
    names = {}
    for i, node in enumerate(nodes):
        name = f"cicd-preflight-pull-{i}"
        kubectl("delete", "pod", "-n", ns, name, "--ignore-not-found", "--wait=true", check=False)
        r = kubectl("apply", "-f", "-", stdin=json.dumps(probe_pod(name, ns, node, image, secrets)), check=False)
        if r.returncode != 0:
            say("WARN", f"node {node}: probe pod not created ({r.stderr.strip()[:200]})")
            continue
        names[name] = node
    deadline = time.time() + timeout
    results = {}
    while names.keys() - results.keys() and time.time() < deadline:
        time.sleep(3)
        for name in names.keys() - results.keys():
            r = kubectl("get", "pod", "-n", ns, name, "-o", "json", check=False)
            if r.returncode == 0:
                res = pull_result(json.loads(r.stdout))
                if res != "pending":
                    results[name] = res
    for name, node in sorted(names.items(), key=lambda x: x[1]):
        res = results.get(name, ("fail", f"no result within {timeout}s"))
        if res == "ok":
            say("OK", f"node {node}: pulls from {harbor_host}")
        else:
            # "Back-off pulling image" hides the cause: the kubelet's "Failed to pull image" event has it
            msg = pull_error(ns, name) or res[1]
            hint = ""
            if re.search(r"x509|certificate", msg, re.I):
                hint = (" - the node does not trust the K-PaaS CA: RKE2 /etc/rancher/rke2/registries.yaml "
                        f"configs.\"{harbor_host}\".tls.ca_file, then restart rke2-server/rke2-agent node by node"
                        if rke2 else " - the node does not trust the K-PaaS CA (cp-portal recover-node-ca.sh)")
            elif re.search(r"no such host|lookup", msg, re.I):
                hint = f" - the node cannot resolve {harbor_host} (node DNS)"
            elif re.search(r"unauthorized|denied|authentication required", msg, re.I):
                hint = " - Harbor refused the credentials (pull secret of the probe's namespace)"
            if tainted.get(node):
                say("WARN", f"node {node} ({', '.join(tainted[node])}: builds and applications are not scheduled "
                            f"there): cannot pull from {harbor_host}: {msg[:300]}{hint}")
            else:
                say("FAIL", f"node {node}: cannot pull {image}: {msg[:300]}{hint}")
    kubectl("delete", "pod", "-n", ns, "-l", "app.kubernetes.io/part-of=cicd-preflight", "--wait=false", check=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("check", choices=["distro", "ingress", "psa", "harbor-pull", "all"])
    ap.add_argument("--ingress-class", default="nginx")
    ap.add_argument("--host", default="")
    ap.add_argument("--namespaces", default="")
    ap.add_argument("--pod-security", default="baseline")
    ap.add_argument("--harbor-host", default="")
    ap.add_argument("--no-pull", action="store_true")
    ap.add_argument("--timeout", type=int, default=120)
    a = ap.parse_args()
    kind, versions = distro(get("nodes"))
    rke2 = kind == "rke2"
    if a.check in ("distro", "all"):
        say("OK", f"Kubernetes: {kind} ({versions})")
        if rke2:
            say("OK", "RKE2: kubectl/crictl in /var/lib/rancher/rke2/bin, kubeconfig /etc/rancher/rke2/rke2.yaml, "
                      "registries /etc/rancher/rke2/registries.yaml")
    if a.check in ("ingress", "all"):
        check_ingress(a.ingress_class, a.host, get("ingressclass"), get("pods", "-A"), get("services", "-A"))
    if a.check in ("psa", "all"):
        check_psa([n for n in a.namespaces.split(",") if n], a.pod_security)
    if a.check in ("harbor-pull", "all") and a.harbor_host and not a.no_pull:
        check_harbor_pull(a.harbor_host, a.timeout, rke2)
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
