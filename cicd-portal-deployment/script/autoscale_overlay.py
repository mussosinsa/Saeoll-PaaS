#!/usr/bin/env python3
"""Autoscaling (HPA) of an application overlay: apps/<app>/overlays/<env> of the gitops repository.

enable : writes autoscale.yaml (HorizontalPodAutoscaler + PodDisruptionBudget), adds it to the resources and
         adds patches between "# cicd-portal autoscale begin/end" markers:
           Deployment: remove /spec/replicas (the HPA owns the replica count; Argo CD must not reset it),
                       CPU request (the HPA target is a percentage of it), spread over the nodes
           Ingress   : sticky session cookie (optional; Istio VirtualService apps: a DestinationRule in autoscale.yaml)
         The kustomize "replicas" entry of the app is removed; its count is kept in a comment for disable.
disable: the reverse (replicas entry restored with the kept count).
stop / start (app-state.sh on an autoscaled overlay): the replicas patch becomes "replace with 0" (an HPA does
         nothing while its target has 0 replicas) / back to "remove".
status : JSON {"enabled", "stopped", "min", "max", ...}

Only JSON6902 patches inline in kustomization.yaml are used (as for the Ingress host), so the overlay works
with the kustomize of every Argo CD version.

Usage: autoscale_overlay.py <enable|disable|stop|start|status> <overlay-dir> <app> [--min N --max N --cpu PCT
       --memory PCT --cpu-request 200m --sticky]
"""
import argparse
import json
import os
import re
import sys

BEGIN, END = "  # cicd-portal autoscale begin", "  # cicd-portal autoscale end"
RES_MARK = "# cicd-portal autoscale"
REPL_MARK = "# cicd-portal autoscale replicas"
KEPT_RE = re.compile(r"^# cicd-portal autoscale: replicas count (\d+)")
CPU_RE = re.compile(r"^[0-9]+m$|^[0-9]+(\.[0-9]+)?$")


class OverlayError(Exception):
    pass


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().splitlines()


def write(path, lines):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def block_end(lines, start):
    """Index after the top-level block that starts at lines[start] ('key:' at column 0)."""
    end = start + 1
    while end < len(lines) and (not lines[end] or lines[end][0].isspace()):
        end += 1
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1
    return end


def top_key(lines, key):
    return next((i for i, l in enumerate(lines) if re.match(rf"^{key}:\s*(#.*)?$", l)), None)


def replicas_entry(lines, app):
    """(start, end, count) of the '- name: <app> / count: N' item of the replicas block, or None."""
    start = top_key(lines, "replicas")
    if start is None:
        return None
    end = block_end(lines, start)
    for i in range(start + 1, end):
        if re.match(r"^\s*-\s*name:\s*" + re.escape(app) + r"\s*$", lines[i]):
            j = i + 1
            while j < end and not re.match(r"^\s*-\s", lines[j]):
                j += 1
            count = next((int(m.group(1)) for l in lines[i:j] if (m := re.match(r"^\s*count:\s*(\d+)", l))), 1)
            return start, end, i, j, count
    return None


def status(overlay, app):
    kfile = os.path.join(overlay, "kustomization.yaml")
    lines = read(kfile)
    text = "\n".join(lines)
    enabled = BEGIN in lines
    info = {"enabled": enabled, "stopped": enabled and "(stopped)" in text.split(REPL_MARK, 1)[-1].split("\n", 1)[0]}
    hpa = os.path.join(overlay, "autoscale.yaml")
    if enabled and os.path.exists(hpa):
        with open(hpa, encoding="utf-8") as fh:
            body = fh.read()
        for key, pattern in (("min", r"minReplicas:\s*(\d+)"), ("max", r"maxReplicas:\s*(\d+)"),
                             ("cpu", r"name: cpu, target: \{type: Utilization, averageUtilization: (\d+)"),
                             ("memory", r"name: memory, target: \{type: Utilization, averageUtilization: (\d+)")):
            m = re.search(pattern, body)
            info[key] = int(m.group(1)) if m else None
        m = re.search(r"path: /spec/template/spec/containers/0/resources/requests/cpu\n\s*value: (\S+)", text)
        info["cpu_request"] = m.group(1) if m else ""
        info["sticky"] = "affinity: cookie" in text or "httpCookie:" in body
    return info


def istio_base(overlay):
    """apiVersion of base/virtualservice.yaml when the app is exposed through Istio (CICD_EXPOSE=istio), else ''."""
    path = os.path.join(overlay, "..", "..", "base", "virtualservice.yaml")
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as fh:
        m = re.search(r"(?m)^apiVersion:\s*(\S+)", fh.read())
    return m.group(1) if m else "networking.istio.io/v1"


def destination_rule(overlay, app, api):
    """Sticky session through the Istio gateway: consistent hash on a cookie for the service of this overlay."""
    text = "\n".join(read(os.path.join(overlay, "kustomization.yaml")))
    ns = (re.search(r"(?m)^namespace:\s*(\S+)", text) or [None, ""])[1]
    suffix = (re.search(r"(?m)^nameSuffix:\s*(\S+)", text) or [None, ""])[1]
    return (f"---\napiVersion: {api}\nkind: DestinationRule\nmetadata:\n  name: {app}\n  labels:\n    app: {app}\n"
            f"spec:\n  host: {app}{suffix}.{ns}.svc.cluster.local\n  trafficPolicy:\n    loadBalancer:\n"
            f"      consistentHash:\n        httpCookie:\n          name: cicd-route\n          ttl: 3600s\n")


def hpa_yaml(app, minimum, maximum, cpu, memory):
    metrics = [f"    - type: Resource\n      resource: {{name: cpu, target: {{type: Utilization, averageUtilization: {cpu}}}}}"]
    if memory:
        metrics.append(f"    - type: Resource\n      resource: {{name: memory, target: {{type: Utilization, "
                       f"averageUtilization: {memory}}}}}")
    doc = f"""# Autoscaling of {app} (CI/CD console 자동 확장). Edited by the portal: change it there.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {app}
  labels:
    app: {app}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {app}
  minReplicas: {minimum}
  maxReplicas: {maximum}
  metrics:
{chr(10).join(metrics)}
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - {{type: Pods, value: 2, periodSeconds: 60}}
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - {{type: Pods, value: 1, periodSeconds: 120}}
"""
    if minimum >= 2:
        doc += f"""---
# keeps at least one pod while nodes are drained (maintenance)
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {app}
  labels:
    app: {app}
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: {app}
"""
    return doc


def patch_block(app, cpu_request, sticky, stopped=False):
    replicas = (["      - op: replace           " + REPL_MARK + " (stopped)", "        path: /spec/replicas",
                 "        value: 0"] if stopped else
                ["      - op: remove            " + REPL_MARK, "        path: /spec/replicas"])
    lines = [BEGIN,
             "  - target:",
             "      kind: Deployment",
             f"      name: {app}",
             "    patch: |-",
             *replicas,
             "      - op: replace",
             "        path: /spec/template/spec/containers/0/resources/requests/cpu",
             f"        value: {cpu_request}",
             "      - op: add",
             "        path: /spec/template/spec/topologySpreadConstraints",
             "        value:",
             "          - maxSkew: 1",
             "            topologyKey: kubernetes.io/hostname",
             "            whenUnsatisfiable: ScheduleAnyway",
             "            labelSelector:",
             "              matchLabels:",
             f"                app: {app}"]
    if sticky:
        lines += ["  - target:",
                  "      kind: Ingress",
                  f"      name: {app}",
                  "    patch: |-",
                  "      - op: add",
                  "        path: /metadata/annotations",
                  "        value:",
                  "          nginx.ingress.kubernetes.io/affinity: cookie",
                  "          nginx.ingress.kubernetes.io/session-cookie-name: cicd-route",
                  "          nginx.ingress.kubernetes.io/session-cookie-max-age: \"3600\""]
    return lines + [END]


def remove_block(lines):
    if BEGIN not in lines:
        return lines, False
    b = lines.index(BEGIN)
    e = lines.index(END, b)
    return lines[:b] + lines[e + 1:], "(stopped)" in "\n".join(lines[b:e])


def enable(overlay, app, minimum, maximum, cpu, memory, cpu_request, sticky):
    if not (1 <= minimum <= maximum <= 50):
        raise OverlayError("min / max: 1 <= min <= max <= 50")
    if not (10 <= cpu <= 95) or (memory and not 10 <= memory <= 95):
        raise OverlayError("target utilization: 10..95 %")
    if not CPU_RE.match(cpu_request):
        raise OverlayError("cpu request: e.g. 200m or 1")
    kfile = os.path.join(overlay, "kustomization.yaml")
    lines = read(kfile)
    lines, was_stopped = remove_block(lines)
    # kustomize replicas entry of the app: removed (kept in a comment for disable)
    entry = replicas_entry(lines, app)
    if entry:
        start, end, i, j, count = entry
        count = int((re.search(r"was (\d+)", "\n".join(lines[i:j])) or [0, count])[1]) if count == 0 else count
        del lines[i:j]
        if not any(re.match(r"^\s*-\s", l) for l in lines[start + 1:end - (j - i)]):
            del lines[start:end - (j - i)]
        lines.insert(0, f"# cicd-portal autoscale: replicas count {count} (restored when autoscaling is turned off)")
    # resources: autoscale.yaml
    if not any(l.strip().startswith("- autoscale.yaml") for l in lines):
        r = top_key(lines, "resources")
        if r is None:
            raise OverlayError("resources: not found in " + kfile)
        lines.insert(r + 1, f"  - autoscale.yaml  {RES_MARK}")
    # patches block
    p = top_key(lines, "patches")
    api = istio_base(overlay)
    block = patch_block(app, cpu_request, sticky and not api, stopped=was_stopped)   # Istio: DestinationRule
    if p is None:
        lines += ["patches:"] + block
    else:
        end = block_end(lines, p)
        lines[end:end] = block
    write(kfile, lines)
    with open(os.path.join(overlay, "autoscale.yaml"), "w", encoding="utf-8") as fh:
        fh.write(hpa_yaml(app, minimum, maximum, cpu, memory) + (destination_rule(overlay, app, api) if sticky and api else ""))
    return status(overlay, app)


def disable(overlay, app):
    kfile = os.path.join(overlay, "kustomization.yaml")
    lines = read(kfile)
    lines, was_stopped = remove_block(lines)
    lines = [l for l in lines if RES_MARK not in l or KEPT_RE.match(l)]
    kept = next((int(m.group(1)) for l in lines if (m := KEPT_RE.match(l))), 1)
    lines = [l for l in lines if not KEPT_RE.match(l)]
    count = f"0  # stopped by the CI/CD portal (was {kept})" if was_stopped else str(kept)
    if replicas_entry(lines, app) is None:
        item = [f"  - name: {app}", f"    count: {count}"]
        r = top_key(lines, "replicas")
        if r is None:
            res = top_key(lines, "patches")
            pos = res if res is not None else len(lines)
            lines[pos:pos] = ["replicas:"] + item
        else:
            lines[r + 1:r + 1] = item
    p = top_key(lines, "patches")
    if p is not None and block_end(lines, p) == p + 1:
        del lines[p]                       # empty patches: left by an overlay that had none
    write(kfile, lines)
    path = os.path.join(overlay, "autoscale.yaml")
    if os.path.exists(path):
        os.remove(path)
    return kept


def set_stopped(overlay, stopped):
    """stop/start of an autoscaled overlay; returns minReplicas (the count to scale to on start)."""
    kfile = os.path.join(overlay, "kustomization.yaml")
    lines = read(kfile)
    i = next((n for n, l in enumerate(lines) if REPL_MARK in l), None)
    if i is None:
        raise OverlayError("not an autoscaled overlay")
    if stopped and "(stopped)" not in lines[i]:
        lines[i:i + 2] = ["      - op: replace           " + REPL_MARK + " (stopped)", "        path: /spec/replicas",
                          "        value: 0"]
    elif not stopped and "(stopped)" in lines[i]:
        lines[i:i + 3] = ["      - op: remove            " + REPL_MARK, "        path: /spec/replicas"]
    write(kfile, lines)
    return 0 if stopped else (status(overlay, "")["min"] or 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["enable", "disable", "stop", "start", "status"])
    ap.add_argument("overlay")
    ap.add_argument("app")
    ap.add_argument("--min", type=int, default=2)
    ap.add_argument("--max", type=int, default=6)
    ap.add_argument("--cpu", type=int, default=70)
    ap.add_argument("--memory", type=int, default=0)
    ap.add_argument("--cpu-request", default="200m")
    ap.add_argument("--sticky", action="store_true")
    a = ap.parse_args()
    try:
        if a.action == "enable":
            print(json.dumps(enable(a.overlay, a.app, a.min, a.max, a.cpu, a.memory, a.cpu_request, a.sticky)))
        elif a.action == "disable":
            print(disable(a.overlay, a.app))
        elif a.action in ("stop", "start"):
            print(set_stopped(a.overlay, a.action == "stop"))
        else:
            print(json.dumps(status(a.overlay, a.app)))
    except (OverlayError, OSError, ValueError) as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
