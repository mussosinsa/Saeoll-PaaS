#!/usr/bin/env python3
"""Checks and discovery for setup-cicd-env.sh (interactive setup of the CI/CD portal on an existing K-PaaS).

  discover               cluster facts as JSON: distribution, domain (CP-Portal ingress), IngressClasses,
                         StorageClasses, TLS secret, namespaces (Keycloak, Harbor, MariaDB, source control)
  ca-from-cluster OUT    K-PaaS CA from the cluster (Helm values / env / ConfigMap of cp-cert-setup) -> OUT
  verify-ca CA DOMAIN    the CA verifies the wildcard TLS secret (cp-portal/<DOMAIN>-tls) and the HTTPS endpoints;
                         names covered by the certificate, expiry. Output [OK]/[WARN]/[FAIL] lines, exit 1 on FAIL
  login WHAT ...         login checks with the password on stdin (never as an argument):
                         keycloak URL USER | harbor URL USER | scm URL USER | mariadb
  harbor-mirror URL USER images of the closed-network Harbor projects (cicd-mirror, base-images) -> suggested
                         cicd-vars values as JSON (password on stdin)
  node-ca-script CA DOMAIN HARBOR_HOST   shell script for the RKE2 nodes (CA in the system store + registries.yaml)
"""
import base64
import datetime
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

PEM_RE = re.compile(r"-----BEGIN CERTIFICATE-----[A-Za-z0-9+/=\s]+?-----END CERTIFICATE-----")


def kubectl(*args, stdin=None):
    try:
        r = subprocess.run(["kubectl", *args], input=stdin, capture_output=True, text=True, timeout=120)
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)
    return r.returncode, r.stdout, r.stderr


def get(*args):
    rc, out, _ = kubectl("get", *args, "-o", "json")
    try:
        return json.loads(out) if rc == 0 and out.strip() else {"items": []}
    except ValueError:
        return {"items": []}


# ------------------------------------------------------------------------------------------- discover ---
def domain_from_ingresses(ingresses):
    """portal.<domain> of CP-Portal, else keycloak./harbor. hosts."""
    hosts = [r.get("host", "") for i in ingresses.get("items", []) for r in (i.get("spec") or {}).get("rules") or []]
    for prefix in ("portal.", "keycloak.", "harbor."):
        for h in hosts:
            if h.startswith(prefix) and "." in h[len(prefix):]:
                return h[len(prefix):]
    return ""


def default_name(items, annotation_keys):
    for i in items:
        ann = (i.get("metadata") or {}).get("annotations") or {}
        if any(ann.get(k) == "true" for k in annotation_keys):
            return i["metadata"]["name"]
    return ""


def discover():
    nodes = get("nodes")
    versions = sorted({n["status"]["nodeInfo"]["kubeletVersion"] for n in nodes["items"]})
    ingresses = get("ingress", "-A")
    classes = get("ingressclass")
    scs = get("storageclass")
    namespaces = {n["metadata"]["name"] for n in get("namespaces")["items"]}
    domain = domain_from_ingresses({"items": [i for i in ingresses["items"] if i["metadata"]["namespace"] == "cp-portal"]}) \
        or domain_from_ingresses(ingresses)
    lb_ip = ""
    for s in get("svc", "-A")["items"]:
        if (s.get("spec") or {}).get("type") == "LoadBalancer" and "ingress" in s["metadata"]["name"]:
            ing = ((s.get("status") or {}).get("loadBalancer") or {}).get("ingress") or []
            if ing:
                lb_ip = ing[0].get("ip") or ing[0].get("hostname") or ""
                break
    tls = bool(domain) and kubectl("-n", "cp-portal", "get", "secret", f"{domain}-tls")[0] == 0
    return {
        "distro": "rke2" if any("+rke2" in v for v in versions) else ("k3s" if any("+k3s" in v for v in versions) else "kubernetes"),
        "versions": versions,
        "nodes": len(nodes["items"]),
        "domain": domain,
        "lb_ip": lb_ip,
        "ingress_classes": [c["metadata"]["name"] for c in classes["items"]],
        "default_ingress_class": default_name(classes["items"], ["ingressclass.kubernetes.io/is-default-class"]),
        "storage_classes": [c["metadata"]["name"] for c in scs["items"]],
        "default_storage_class": default_name(scs["items"], ["storageclass.kubernetes.io/is-default-class",
                                                             "storageclass.beta.kubernetes.io/is-default-class"]),
        "tls_secret": tls,
        "namespaces": {ns: ns in namespaces for ns in ("cp-portal", "keycloak", "harbor", "mariadb", "cp-source-control")},
    }


# ------------------------------------------------------------------------------------------------ CA ---
def first_pem(text):
    m = PEM_RE.search(text or "")
    return m.group(0).strip() + "\n" if m else ""


def ca_from_cluster(ns="kube-system"):
    """(pem, where) of the CA that cp-cert-setup installs on the nodes."""
    # 1. Helm release values (deploy-cp-portal.sh: --set data.target.cert=<ca.crt>)
    try:
        r = subprocess.run(["helm", "list", "-n", ns, "-o", "json"], capture_output=True, text=True, timeout=60)
        for rel in json.loads(r.stdout or "[]") if r.returncode == 0 else []:
            if "cert-setup" in rel.get("name", "") or "cert-setup" in rel.get("chart", ""):
                v = subprocess.run(["helm", "get", "values", rel["name"], "-n", ns, "-o", "json"],
                                   capture_output=True, text=True, timeout=60)
                pem = first_pem(json.dumps(json.loads(v.stdout or "{}"))) if v.returncode == 0 else ""
                pem = pem.replace("\\n", "\n")
                if pem:
                    return pem, f"helm values {ns}/{rel['name']}"
    except (FileNotFoundError, subprocess.TimeoutExpired, ValueError):
        pass
    # 2. the cert-setup DaemonSet: literal env or the ConfigMap / Secret it refers to
    for ds in get("daemonsets", "-n", ns)["items"]:
        if "cert-setup" not in ds["metadata"]["name"]:
            continue
        for c in ds["spec"]["template"]["spec"].get("containers", []) + ds["spec"]["template"]["spec"].get("initContainers", []):
            for e in c.get("env") or []:
                pem = first_pem(e.get("value", "").replace("\\n", "\n"))
                if pem:
                    return pem, f"daemonset {ns}/{ds['metadata']['name']}"
                ref = (e.get("valueFrom") or {})
                if "configMapKeyRef" in ref:
                    cm = get("configmap", ref["configMapKeyRef"]["name"], "-n", ns)
                    pem = first_pem(((cm.get("data") or {}).get(ref["configMapKeyRef"]["key"])) or "")
                elif "secretKeyRef" in ref:
                    s = get("secret", ref["secretKeyRef"]["name"], "-n", ns)
                    raw = (s.get("data") or {}).get(ref["secretKeyRef"]["key"]) or ""
                    pem = first_pem(base64.b64decode(raw).decode(errors="replace")) if raw else ""
                if pem:
                    return pem, f"daemonset {ns}/{ds['metadata']['name']} ({e.get('name')})"
    # 3. a ConfigMap of cert-setup
    for cm in get("configmaps", "-n", ns)["items"]:
        if "cert" in cm["metadata"]["name"]:
            for value in (cm.get("data") or {}).values():
                pem = first_pem(value)
                if pem:
                    return pem, f"configmap {ns}/{cm['metadata']['name']}"
    return "", ""


def openssl(*args, stdin=None):
    r = subprocess.run(["openssl", *args], input=stdin, capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout + r.stderr


def cert_info(pem):
    """(names, not_after datetime, is_ca) of a PEM certificate (openssl)."""
    rc, out = openssl("x509", "-noout", "-subject", "-enddate", "-ext", "subjectAltName,basicConstraints", stdin=pem)
    names = re.findall(r"DNS:([^,\s]+)", out)
    cn = re.search(r"CN\s*=\s*([^,/\n]+)", out)
    if cn and not names:
        names = [cn.group(1).strip()]
    end = re.search(r"notAfter=(.+)", out)
    not_after = None
    if end:
        try:
            not_after = datetime.datetime.strptime(end.group(1).strip(), "%b %d %H:%M:%S %Y %Z")
        except ValueError:
            pass
    return names, not_after, "CA:TRUE" in out


def covers(names, host):
    for n in names:
        if n == host or (n.startswith("*.") and host.count(".") == n.count(".") and host.endswith(n[1:])):
            return True
    return False


def verify_ca(ca_path, domain, connect=None, now=None):
    """Lines of [OK]/[WARN]/[FAIL] and whether something failed."""
    lines, failed = [], False

    def say(level, msg):
        nonlocal failed
        lines.append(f"[{level}]{' ' * (5 - len(level))}{msg}")
        failed = failed or level == "FAIL"
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    try:
        with open(ca_path, encoding="utf-8") as fh:
            ca = fh.read()
    except OSError as e:
        say("FAIL", f"CA file {ca_path}: {e}")
        return lines, failed
    if "PRIVATE KEY" in ca:
        say("FAIL", f"{ca_path} contains a private key - use the CA certificate (ca.crt) only, never ca.key")
        return lines, failed
    if not first_pem(ca):
        say("FAIL", f"{ca_path} is not a PEM certificate")
        return lines, failed
    _, ca_end, is_ca = cert_info(first_pem(ca))
    if not is_ca:
        say("WARN", f"{ca_path} is not marked as a CA (basicConstraints CA:TRUE) - is it the server certificate?")
    if ca_end and ca_end < now:
        say("FAIL", f"CA expired on {ca_end:%Y-%m-%d}")
    # wildcard certificate of CP-Portal
    rc, out, err = kubectl("-n", "cp-portal", "get", "secret", f"{domain}-tls", "-o", "jsonpath={.data.tls\\.crt}")
    if rc != 0 or not out:
        say("FAIL", f"TLS secret cp-portal/{domain}-tls not found (deploy CP-Portal first, or check the domain)")
    else:
        server = base64.b64decode(out).decode(errors="replace")
        with tempfile.NamedTemporaryFile("w", suffix=".crt", delete=False) as fh:
            fh.write(server)
        try:
            rc, vout = openssl("verify", "-CAfile", ca_path, fh.name)
        finally:
            os.unlink(fh.name)
        if rc == 0:
            say("OK", f"CA verifies the TLS certificate cp-portal/{domain}-tls")
        else:
            say("FAIL", f"CA does not verify cp-portal/{domain}-tls ({vout.strip().splitlines()[-1][:160]}) - wrong ca.crt?")
        names, end, _ = cert_info(first_pem(server))
        missing = [h for h in (f"{p}.{domain}" for p in ("jenkins", "argocd", "cicd", "gitlab", "harbor", "keycloak",
                                                          "scm", "scm-manager")) if not covers(names, h)]
        if missing:
            say("FAIL", f"TLS certificate does not cover {', '.join(missing)} (names: {', '.join(names[:6])}) - "
                        f"a wildcard *.{domain} certificate is needed")
        else:
            say("OK", f"TLS certificate covers *.{domain}")
        if end:
            days = (end - now).days
            say("FAIL" if days < 0 else "WARN" if days < 30 else "OK",
                f"TLS certificate valid until {end:%Y-%m-%d} ({days} days)")
    # endpoints
    connect = connect or tls_connect
    for host in (f"keycloak.{domain}", f"harbor.{domain}"):
        err = connect(host, ca_path)
        say("OK" if not err else "FAIL", f"https://{host}: " + ("TLS verified with the CA" if not err else err))
    return lines, failed


def tls_connect(host, ca_path, port=443):
    try:
        ctx = ssl.create_default_context(cafile=ca_path)
        with socket.create_connection((host, port), timeout=10) as sock:
            with ctx.wrap_socket(sock, server_hostname=host):
                return ""
    except ssl.SSLCertVerificationError as e:
        return f"certificate not verified ({e.verify_message})"
    except (OSError, ssl.SSLError) as e:
        return f"not reachable ({e})"


# --------------------------------------------------------------------------------------------- logins ---
def _ctx():
    ca = os.environ.get("CA_FILE", "")
    return ssl.create_default_context(cafile=ca) if ca and os.path.isfile(ca) else ssl.create_default_context()


def http(method, url, headers=None, form=None):
    body = urllib.parse.urlencode(form).encode() if form is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers=dict(headers or {}))
    try:
        with urllib.request.urlopen(req, context=_ctx(), timeout=30) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:200]
    except (urllib.error.URLError, OSError) as e:
        return 0, str(getattr(e, "reason", e))


def basic(user, password):
    return {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()}


def login(what, args, password):
    """'' when the login works, else the reason."""
    if what == "keycloak":
        url, user = args
        code, body = http("POST", f"{url.rstrip('/')}/realms/master/protocol/openid-connect/token",
                          form={"grant_type": "password", "client_id": "admin-cli", "username": user, "password": password})
        return "" if code == 200 else f"HTTP {code} {body[:120]}"
    if what == "harbor":
        url, user = args
        code, body = http("GET", f"{url.rstrip('/')}/api/v2.0/users/current", basic(user, password))
        return "" if code == 200 else f"HTTP {code} {body[:120]}"
    if what == "scm":
        url, user = args
        code, body = http("GET", f"{url.rstrip('/')}/api/rest/repositories.json", basic(user, password))
        if code == 401:
            return "HTTP 401 - the git password set in scm.<domain> > 내정보 관리 (not the Keycloak password)"
        return "" if code == 200 else f"HTTP {code} {body[:120]}"
    if what == "mariadb":
        rc, out, _ = kubectl("-n", "mariadb", "get", "pods", "-o", "name")
        pods = [p.split("/", 1)[1] for p in out.split() if "mariadb" in p]
        if not pods:
            return "no MariaDB pod in namespace mariadb"
        script = ('IFS= read -r MYSQL_PWD; export MYSQL_PWD; c=$(command -v mariadb || command -v mysql); '
                  '"$c" -uroot -N -B -e "SELECT 1"')
        rc, out, err = kubectl("-n", "mariadb", "exec", "-i", pods[0], "--", "sh", "-c", script, stdin=password + "\n")
        return "" if rc == 0 and out.strip() == "1" else (err.strip()[:160] or "login failed")
    raise SystemExit(f"unknown login {what}")


# ------------------------------------------------------------------------------------- harbor mirror ---
def harbor_mirror(url, user, password):
    """cicd-vars values for images already in the Harbor of a closed network (load-to-harbor.sh)."""
    host = urllib.parse.urlparse(url).netloc
    found = {}
    for project in ("cicd-mirror", "base-images"):
        code, body = http("GET", f"{url.rstrip('/')}/api/v2.0/projects/{project}/repositories?page_size=100",
                          basic(user, password))
        if code != 200:
            continue
        for repo in json.loads(body or "[]"):
            name = repo["name"].split("/", 1)[1]
            enc = urllib.parse.quote(urllib.parse.quote(name, safe=""), safe="")
            code, arts = http("GET", f"{url.rstrip('/')}/api/v2.0/projects/{project}/repositories/{enc}/artifacts"
                                     "?with_tag=true&page_size=50", basic(user, password))
            tags = [t["name"] for a in (json.loads(arts or "[]") if code == 200 else [])
                    for t in a.get("tags") or []]
            found[f"{project}/{name}"] = tags
    return mirror_values(host, found)


def mirror_values(host, found):
    values = {}
    jenkins = [t for t in found.get("cicd-mirror/jenkins", []) if t.endswith("-plugins")]
    tool = [t for t in found.get("cicd-mirror/jenkins", []) if not t.endswith("-plugins")]
    if jenkins:
        values["JENKINS_IMAGE"] = f"{host}/cicd-mirror/jenkins:{sorted(jenkins)[-1]}"
    if tool:
        values["JENKINS_TOOL_IMAGE"] = f"{host}/cicd-mirror/jenkins:{sorted(tool)[-1]}"
    if found.get("cicd-mirror/kaniko-executor"):
        values["KANIKO_IMAGE"] = f"{host}/cicd-mirror/kaniko-executor:{sorted(found['cicd-mirror/kaniko-executor'])[-1]}"
    if any(k.startswith("base-images/") for k in found):
        values["CICD_BASE_REGISTRY"] = f"{host}/base-images"
        values["CICD_DOCKERHUB"] = f"{host}/base-images"
    if found.get("base-images/mariadb"):
        values["MARIADB_IMAGE"] = f"{host}/base-images/mariadb:{sorted(found['base-images/mariadb'])[-1]}"
    return values


# ------------------------------------------------------------------------------------- RKE2 node CA ---
def node_ca_script(ca_pem, domain, harbor_host):
    """Run as root on every RKE2 node: the CA in the system trust store and for RKE2's containerd (Harbor)."""
    return f"""#!/bin/bash
# K-PaaS CA on an RKE2 node (generated by setup-cicd-env.sh). Run as root on EVERY node (control plane too).
# Only the public CA certificate is written; the CA private key is never needed.
set -euo pipefail
cat > /etc/pki/ca-trust/source/anchors/{domain}-ca.crt <<'CA'
{ca_pem.strip()}
CA
update-ca-trust extract
mkdir -p /etc/rancher/rke2
cp /etc/pki/ca-trust/source/anchors/{domain}-ca.crt /etc/rancher/rke2/{domain}-ca.crt
REG=/etc/rancher/rke2/registries.yaml
if ! grep -q '"{harbor_host}"' "$REG" 2>/dev/null; then
  [[ -f "$REG" ]] && cp "$REG" "$REG.bak.$(date +%Y%m%d%H%M%S)"
  grep -q '^configs:' "$REG" 2>/dev/null || echo 'configs:' >> "$REG"
  sed -i '/^configs:/a\\  "{harbor_host}":\\n    tls:\\n      ca_file: /etc/rancher/rke2/{domain}-ca.crt' "$REG"
fi
if systemctl is-active --quiet rke2-server; then systemctl restart rke2-server
elif systemctl is-active --quiet rke2-agent; then systemctl restart rke2-agent; fi
echo "[OK] CA installed on $(hostname) (RKE2 restarted: running pods keep running)"
"""


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "discover":
        print(json.dumps(discover()))
    elif cmd == "ca-from-cluster":
        pem, where = ca_from_cluster()
        if not pem:
            sys.exit(1)
        with open(args[0], "w", encoding="utf-8") as fh:
            fh.write(pem)
        print(where)
    elif cmd == "verify-ca":
        lines, failed = verify_ca(args[0], args[1])
        print("\n".join(lines))
        sys.exit(1 if failed else 0)
    elif cmd == "login":
        reason = login(args[0], args[1:], sys.stdin.readline().rstrip("\n"))
        if reason:
            print(reason)
            sys.exit(1)
    elif cmd == "harbor-mirror":
        print(json.dumps(harbor_mirror(args[0], args[1], sys.stdin.readline().rstrip("\n"))))
    elif cmd == "node-ca-script":
        with open(args[0], encoding="utf-8") as fh:
            print(node_ca_script(fh.read(), args[1], args[2]), end="")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
