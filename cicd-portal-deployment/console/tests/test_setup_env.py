"""setup-cicd-env.sh / setup_check.py: discovery, certificates, RKE2 node CA script, the interactive flow."""
import base64
import datetime
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

SCRIPT_DIR = pathlib.Path(os.environ.get("CICD_SCRIPT_DIR") or pathlib.Path(__file__).resolve().parents[2] / "script")
sys.path.insert(0, str(SCRIPT_DIR))
import setup_check as sc  # noqa: E402

HAVE_OPENSSL = shutil.which("openssl") is not None


def make_certs(d, domain, names=None):
    """CA + server certificate for *.domain (openssl)."""
    names = names or [f"*.{domain}", domain]
    run = lambda *a: subprocess.run(["openssl", *a], cwd=d, check=True, capture_output=True)  # noqa: E731
    run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.crt", "-days", "30",
        "-subj", "/CN=test-ca", "-addext", "basicConstraints=critical,CA:TRUE")
    run("req", "-newkey", "rsa:2048", "-nodes", "-keyout", "srv.key", "-out", "srv.csr", "-subj", f"/CN={domain}")
    pathlib.Path(d, "ext").write_text("subjectAltName=" + ",".join(f"DNS:{n}" for n in names) + "\n")
    run("x509", "-req", "-in", "srv.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial", "-out", "srv.crt",
        "-days", "20", "-extfile", "ext")
    return pathlib.Path(d, "ca.crt"), pathlib.Path(d, "srv.crt").read_text()


class DiscoverTest(unittest.TestCase):
    def test_domain(self):
        ing = {"items": [{"metadata": {"namespace": "cp-portal"}, "spec": {"rules": [{"host": "portal.k.example.kr"}]}}]}
        self.assertEqual(sc.domain_from_ingresses(ing), "k.example.kr")
        ing = {"items": [{"metadata": {"namespace": "x"}, "spec": {"rules": [{"host": "keycloak.10.0.0.1.nip.io"}]}}]}
        self.assertEqual(sc.domain_from_ingresses(ing), "10.0.0.1.nip.io")

    def test_discover_rke2(self):
        objs = {
            "nodes": {"items": [{"status": {"nodeInfo": {"kubeletVersion": "v1.30.4+rke2r1"}}}]},
            "ingress": {"items": [{"metadata": {"namespace": "cp-portal", "name": "ui"},
                                   "spec": {"rules": [{"host": "portal.k.kr"}]}}]},
            "ingressclass": {"items": [{"metadata": {"name": "nginx", "annotations": {
                "ingressclass.kubernetes.io/is-default-class": "true"}}}]},
            "storageclass": {"items": [{"metadata": {"name": "local-path"}},
                                       {"metadata": {"name": "nfs", "annotations": {
                                           "storageclass.kubernetes.io/is-default-class": "true"}}}]},
            "namespaces": {"items": [{"metadata": {"name": n}} for n in ("cp-portal", "keycloak", "harbor")]},
            "svc": {"items": []},
        }
        with mock.patch.object(sc, "get", side_effect=lambda kind, *a: objs[kind]), \
                mock.patch.object(sc, "kubectl", return_value=(0, "", "")):
            d = sc.discover()
        self.assertEqual((d["distro"], d["domain"], d["default_storage_class"], d["tls_secret"]),
                         ("rke2", "k.kr", "nfs", True))
        self.assertFalse(d["namespaces"]["mariadb"])

    def test_ca_from_daemonset_configmap(self):
        pem = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"
        ds = {"items": [{"metadata": {"name": "cp-cert-setup-daemonset"}, "spec": {"template": {"spec": {"containers": [
            {"env": [{"name": "CA_CERT", "valueFrom": {"configMapKeyRef": {"name": "cp-cert", "key": "cert"}}}]}]}}}}]}
        objs = {"daemonsets": ds, "configmap": {"data": {"cert": pem}}, "configmaps": {"items": []}}
        with mock.patch.object(sc.subprocess, "run", side_effect=FileNotFoundError), \
                mock.patch.object(sc, "get", side_effect=lambda kind, *a: objs[kind]):
            got, where = sc.ca_from_cluster()
        self.assertEqual(got, pem + "\n")
        self.assertIn("cp-cert-setup-daemonset", where)

    def test_mirror_values(self):
        v = sc.mirror_values("h", {"cicd-mirror/jenkins": ["2.479.3-jdk17-plugins", "lts-jdk17"],     # newest first
                                   "cicd-mirror/kaniko-executor": ["v1"], "base-images/mariadb": ["11.4"],
                                   "base-images/node": ["20-alpine"], "cicd-portal/cicd-console": ["1.0.2", "1.0.1"]})
        self.assertEqual(v["JENKINS_IMAGE"], "h/cicd-mirror/jenkins:2.479.3-jdk17-plugins")
        self.assertEqual(v["JENKINS_TOOL_IMAGE"], "h/cicd-mirror/jenkins:lts-jdk17")
        self.assertEqual((v["CICD_BASE_REGISTRY"], v["MARIADB_IMAGE"]), ("h/base-images", "h/base-images/mariadb:11.4"))
        self.assertEqual(v["CONSOLE_IMAGE_TAG"], "1.0.2")
        self.assertNotIn("SECURITY_IMAGE_TAG", v)


class HarborFallbackTest(unittest.TestCase):
    def test_list_file_when_api_fails(self):
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        (tmp / "list").write_text("cicd-portal/cicd-console:1.0.2\tn\tprivate\ncicd-portal/cicd-console:1.0.1\tn\tprivate\n"
                                  "cicd-mirror/jenkins:2.5-plugins\tn\tpublic\nmirror/quay.io/argoproj/argocd:v2\tn\tpublic\n"
                                  "mirror/docker.io/library/redis:7\tn\tpublic\tall\n")
        with mock.patch.object(sc, "http", return_value=(500, "internal server error")):
            v = sc.harbor_mirror("https://harbor.k.kr", "admin", "pw", str(tmp / "list"))
        self.assertEqual(v["CONSOLE_IMAGE_TAG"], "1.0.2")
        self.assertEqual(v["JENKINS_IMAGE"], "harbor.k.kr/cicd-mirror/jenkins:2.5-plugins")
        self.assertEqual(v["MIRROR_REGISTRIES"], "docker.io quay.io")


@unittest.skipUnless(HAVE_OPENSSL, "openssl")
class CertTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def verify(self, ca, server):
        tls = base64.b64encode(server.encode()).decode()
        with mock.patch.object(sc, "kubectl", return_value=(0, tls, "")):
            return sc.verify_ca(str(ca), "k.kr", connect=lambda h, c: "")

    def test_good_ca(self):
        ca, server = make_certs(self.tmp, "k.kr")
        lines, failed = self.verify(ca, server)
        self.assertFalse(failed, lines)
        self.assertTrue(any("covers *.k.kr" in line for line in lines))
        self.assertTrue(any(line.startswith("[WARN]") and "valid until" in line for line in lines))   # < 30 days

    def test_wrong_ca_and_names(self):
        ca, _ = make_certs(self.tmp, "k.kr")
        other = tempfile.mkdtemp(); self.addCleanup(shutil.rmtree, other)
        _, server = make_certs(other, "k.kr", names=["portal.k.kr"])
        lines, failed = self.verify(ca, server)
        self.assertTrue(failed)
        self.assertTrue(any("does not verify" in line for line in lines))
        self.assertTrue(any("does not cover jenkins.k.kr" in line for line in lines))

    def test_private_key_refused(self):
        make_certs(self.tmp, "k.kr")
        lines, failed = self.verify(pathlib.Path(self.tmp, "ca.key"), "")
        self.assertTrue(failed)
        self.assertIn("never ca.key", lines[0])

    def test_node_script(self):
        ca, _ = make_certs(self.tmp, "k.kr")
        root = pathlib.Path(self.tmp, "root")
        (root / "anchors").mkdir(parents=True)
        (root / "rke2").mkdir()
        (root / "rke2/registries.yaml").write_text('mirrors:\n  docker.io:\n    endpoint:\n      - "http://m:5000"\n')
        script = sc.node_ca_script(ca.read_text(), "k.kr", "harbor.k.kr", ["docker.io", "quay.io", "bad name"])
        self.assertNotIn("PRIVATE KEY", script)
        script = script.replace("/etc/pki/ca-trust/source/anchors", str(root / "anchors")) \
                       .replace("/etc/rancher/rke2", str(root / "rke2"))
        bindir = pathlib.Path(self.tmp, "bin"); bindir.mkdir()
        for tool in ("update-ca-trust", "systemctl"):
            (bindir / tool).write_text("#!/bin/sh\nexit 1\n" if tool == "systemctl" else "#!/bin/sh\nexit 0\n")
            (bindir / tool).chmod(0o755)
        env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}"}
        for _ in range(2):                                   # second run: nothing added again
            subprocess.run(["bash", "-c", script], check=True, env=env, capture_output=True)
        reg = (root / "rke2/registries.yaml").read_text()
        self.assertEqual(reg.count('"harbor.k.kr":'), 1)
        self.assertIn(f'configs:\n  "harbor.k.kr":\n    tls:\n      ca_file: {root}/rke2/k.kr-ca.crt', reg)
        self.assertIn("mirrors:", reg)
        self.assertIn('  "quay.io":\n    endpoint:\n      - "https://harbor.k.kr"\n    rewrite:\n'
                      '      "^(.*)$": "mirror/quay.io/$1"', reg)
        self.assertEqual(reg.count("quay.io"), 2)                    # added once (second run: kept)
        self.assertNotIn("mirror/docker.io", reg)                    # an existing docker.io mirror is kept
        self.assertNotIn("bad name", script)
        self.assertTrue((root / "anchors/k.kr-ca.crt").read_text().startswith("-----BEGIN CERTIFICATE-----"))


STUB_CHECK = r'''#!/usr/bin/env python3
import json, sys
cmd = sys.argv[1]
if cmd == "discover":
    print(json.dumps({"distro": "rke2", "versions": ["v1.30.4+rke2r1"], "nodes": 3, "domain": "k.kr", "lb_ip": "10.0.0.5",
                      "ingress_classes": ["nginx"], "default_ingress_class": "nginx",
                      "storage_classes": ["local-path", "nfs"], "default_storage_class": "nfs", "tls_secret": True,
                      "namespaces": {n: True for n in ("cp-portal", "keycloak", "harbor", "mariadb", "cp-source-control")}}))
elif cmd == "verify-ca":
    print("[OK]   CA verifies")
elif cmd == "login":
    pw = sys.stdin.readline().rstrip("\n")
    if pw not in ("good", "scm-good"):
        print("HTTP 401"); sys.exit(1)
elif cmd == "harbor-mirror":
    print(json.dumps({"JENKINS_IMAGE": "harbor.k.kr/cicd-mirror/jenkins:2.4-plugins",
                      "CONSOLE_IMAGE_TAG": "1.0.2", "MIRROR_REGISTRIES": "quay.io ghcr.io"}))
elif cmd == "node-ca-script":
    print("#!/bin/bash")
    print("# mirrors: " + " ".join(sys.argv[5:]))
'''


class WizardTest(unittest.TestCase):
    """setup-cicd-env.sh with stubs: answers on stdin, files written, passwords never in cicd-vars.local.sh."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        script = self.tmp / "cicd-portal-deployment/script"
        script.mkdir(parents=True)
        shutil.copy(SCRIPT_DIR / "setup-cicd-env.sh", script)
        (script / "setup_check.py").write_text(STUB_CHECK)
        (script / "deploy-cicd-portal.sh").write_text('#!/bin/bash\necho "deploy $* SCM=${SCM_ADMIN_PASSWORD:+set}" >> "$(dirname "$0")/deploy.log"\n')
        (script / "deploy-cicd-portal.sh").chmod(0o755)
        portal = self.tmp / "cp-portal-deployment"
        (portal / "script").mkdir(parents=True)
        (portal / "certs").mkdir()
        (portal / "certs/ca.crt").write_text("-----BEGIN CERTIFICATE-----\nAA\n-----END CERTIFICATE-----\n")
        (portal / "script/cp-portal-vars.sh").write_text(textwrap.dedent('''\
            HOST_DOMAIN="k.kr"
            K8S_STORAGECLASS="cp-storageclass"
            KEYCLOAK_URL="https://keycloak.${HOST_DOMAIN}"
            KEYCLOAK_ADMIN_USERNAME="admin"
            KEYCLOAK_ADMIN_PASSWORD="good"
            KEYCLOAK_CP_REALM="cp-realm"
            REPOSITORY_URL="https://harbor.${HOST_DOMAIN}"
            REPOSITORY_USERNAME="admin"
            REPOSITORY_PASSWORD="Harbor12345"
            DATABASE_USER_PASSWORD="good"
            '''))
        bindir = self.tmp / "bin"
        bindir.mkdir()
        for name, body in (("kubectl", "exit 0"), ("getent", "exit 0"),
                           ("openssl", 'echo "SHA256 Fingerprint=AA:BB"')):
            (bindir / name).write_text(f"#!/bin/sh\n{body}\n")
            (bindir / name).chmod(0o755)
        self.script = script
        self.env = {"PATH": f"{bindir}:{os.environ['PATH']}", "HOME": str(self.tmp / "home"), "LANG": "C.UTF-8"}

    def run_wizard(self, answers, *args):
        return subprocess.run(["bash", str(self.script / "setup-cicd-env.sh"), *args], input=answers,
                              capture_output=True, text=True, env=self.env, timeout=60)

    def test_interactive(self):
        answers = "\n".join([
            "",            # domain k.kr
            "good",        # Harbor password (the file one fails)
            "",            # sources: scm (source control present)
            "",            # SCM admin scmadmin
            "scm-good",    # SCM git password
            "",            # StorageClass: cp-storageclass not in the list -> default nfs
            "",            # IngressClass nginx
            "", "",        # Pod Security baseline / vendor empty
            "",            # closed network: no
            "",            # save the SCM password: no
        ]) + "\n"
        r = self.run_wizard(answers, "--no-deploy")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        local = (self.script / "cicd-vars.local.sh").read_text()
        self.assertIn("cicd_set CICD_SOURCES scm", local)
        self.assertIn("cicd_set K8S_STORAGECLASS nfs", local)
        self.assertIn("cicd_set CICD_POD_SECURITY baseline", local)
        self.assertIn("cicd_set PORTAL_VARS", local)                 # Harbor password changed -> portal-vars.local.sh
        self.assertNotIn("good", local)                             # no password in cicd-vars.local.sh
        plocal = self.script / "portal-vars.local.sh"
        self.assertEqual(stat.S_IMODE(plocal.stat().st_mode), 0o600)
        self.assertIn("REPOSITORY_PASSWORD=good", plocal.read_text())
        self.assertNotIn("scm-good", plocal.read_text())            # the SCM password is not stored
        self.assertIn("deploy preflight SCM=set", (self.script / "deploy.log").read_text())
        self.assertFalse((self.tmp / "home/.config/cicd-portal/secrets.env").exists())
        # re-run with --yes: the values of the first run are the defaults, the SCM password comes from the env
        self.env["SCM_ADMIN_PASSWORD"] = "scm-good"
        r = self.run_wizard("", "--yes", "--no-deploy")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("cicd_set PORTAL_VARS", (self.script / "cicd-vars.local.sh").read_text())
        self.assertIn("K8S_STORAGECLASS=nfs", plocal.read_text())

    def test_closed_network_loads_backup(self):
        offline = self.tmp / "offline"
        offline.mkdir()
        (offline / "load-to-harbor.sh").write_text(
            '#!/bin/bash\necho "load $* host=$HARBOR_HOST user=$HARBOR_USER pw=${HARBOR_PASSWORD:+set}" >> '
            f'"{self.tmp}/load.log"\n')
        (offline / "load-to-harbor.sh").chmod(0o755)
        backup = self.tmp / "harbor-export-20261110"
        (backup / "charts").mkdir(parents=True)
        (backup / "charts/versions.env").write_text('JENKINS_CHART_VERSION="5.8.10"\nARGOCD_CHART_VERSION="7.8.0"\n')
        bindir = self.tmp / "bin"
        (bindir / "skopeo").write_text("#!/bin/sh\nexit 0\n")
        (bindir / "skopeo").chmod(0o755)
        answers = "\n".join([
            "", "good", "", "", "scm-good", "", "", "", "",   # as test_interactive
            "y",                       # closed network
            str(backup),               # backup folder
            "",                        # register: yes
            "",                        # charts folder: <backup>/charts
            "", "",                    # JENKINS_IMAGE, CONSOLE_IMAGE_TAG from Harbor
            "",                        # Nexus: none
            "y",                       # ran the node script on every node
            "",                        # save the SCM password: no
        ]) + "\n"
        r = self.run_wizard(answers, "--no-deploy")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        load = (self.tmp / "load.log").read_text()
        self.assertIn(f"load {backup} host=harbor.k.kr user=admin pw=set", load)
        self.assertNotIn("good", load)                                # password only in the environment
        local = (self.script / "cicd-vars.local.sh").read_text()
        self.assertIn(f"cicd_set CICD_CHART_DIR {backup}/charts", local)
        self.assertIn("cicd_set JENKINS_CHART_VERSION 5.8.10", local)
        self.assertIn("cicd_set JENKINS_IMAGE harbor.k.kr/cicd-mirror/jenkins:2.4-plugins", local)
        self.assertIn("cicd_set CONSOLE_IMAGE_TAG 1.0.2", local)
        self.assertNotIn("MIRROR_REGISTRIES", local)
        self.assertIn(f"cicd_set CICD_IMAGE_LOADED {backup}", local)    # re-run: "register?" defaults to No
        node = (self.tmp / "cicd-portal-deployment/values/rke2-node-ca.sh").read_text()
        self.assertIn("# mirrors: quay.io ghcr.io", node)

    def test_yes_fails_without_password(self):
        r = self.run_wizard("", "--yes", "--no-deploy")              # Harbor password of the file fails
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not set", r.stderr)


class CicdVarsLocalTest(unittest.TestCase):
    def test_local_file_and_env_override(self):
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        shutil.copy(SCRIPT_DIR / "cicd-vars.sh", tmp)
        (tmp / "cicd-vars.local.sh").write_text('cicd_set INGRESS_CLASS_NAME "rke2"\ncicd_set CICD_SOURCES "scm"\n')
        show = f'source {tmp}/cicd-vars.sh; echo "$CICD_SOURCES|$INGRESS_CLASS_NAME"'
        out = subprocess.run(["bash", "-c", show], capture_output=True, text=True, env={"PATH": os.environ["PATH"]})
        self.assertEqual(out.stdout.strip(), "scm|rke2")
        out = subprocess.run(["bash", "-c", show], capture_output=True, text=True,
                             env={"PATH": os.environ["PATH"], "CICD_SOURCES": "gitlab"})
        self.assertEqual(out.stdout.strip(), "gitlab|rke2")          # exported by the caller: wins


if __name__ == "__main__":
    unittest.main()
