"""CICD_EXPOSE=istio: VirtualServices on the Istio Gateway instead of Ingresses (portal and applications)."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

SCRIPT_DIR = pathlib.Path(os.environ.get("CICD_SCRIPT_DIR") or pathlib.Path(__file__).resolve().parents[2] / "script")
sys.path.insert(0, str(SCRIPT_DIR))
import cluster_check as cc  # noqa: E402
import expose_overlay  # noqa: E402

GW = {"metadata": {"name": "cp-gateway", "namespace": "istio-system"},
      "spec": {"selector": {"istio": "ingressgateway"},
               "servers": [{"port": {"number": 80, "protocol": "HTTP"}, "hosts": ["*"]},
                           {"port": {"number": 443, "protocol": "HTTPS"}, "hosts": ["*.192.168.10.110.nip.io"]}]}}
SVCS = {"items": [{"metadata": {"name": "istio-ingressgateway"},
                   "spec": {"selector": {"app": "istio-ingressgateway", "istio": "ingressgateway"}},
                   "status": {"loadBalancer": {"ingress": [{"ip": "192.168.10.110"}]}}},
                  {"metadata": {"name": "istiod"}, "spec": {"selector": {"app": "istiod"}}, "status": {}}]}
D = "192.168.10.110.nip.io"


def run_check(*args, **kwargs):
    cc.FAILED.clear()
    import contextlib
    import io
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        cc.check_istio(*args, **kwargs)
    return out.getvalue(), list(cc.FAILED)


def bash(script, **env):
    return subprocess.run(["bash", "-c", f"source {SCRIPT_DIR}/lib.sh; {script}"], capture_output=True, text=True,
                          env={**os.environ, **env}, check=True).stdout


class GatewayCheckTest(unittest.TestCase):
    def test_ok(self):
        out, failed = run_check("istio-system/cp-gateway", [f"keycloak.{D}", f"cicd.{D}"], GW, SVCS,
                                resolve=lambda h: ["192.168.10.110"])
        self.assertEqual(failed, [])
        self.assertIn("HTTPS hosts cover", out)
        self.assertIn("(Istio ingress gateway)", out)

    def test_hosts_not_covered_and_missing_gateway(self):
        gw = {**GW, "spec": {**GW["spec"], "servers": [{"port": {"protocol": "HTTPS"}, "hosts": [f"portal.{D}"]}]}}
        _, failed = run_check("istio-system/cp-gateway", [f"gitlab.{D}"], gw, SVCS, resolve=lambda h: ["192.168.10.110"])
        self.assertTrue(any("do not include gitlab." in f for f in failed))
        _, failed = run_check("istio-system/cp-gateway", [f"gitlab.{D}"], None, SVCS)
        self.assertTrue(any("not found" in f for f in failed))

    def test_dns_elsewhere_warns(self):
        out, failed = run_check("istio-system/cp-gateway", [f"cicd.{D}"], GW, SVCS, resolve=lambda h: ["10.0.0.9"])
        self.assertEqual(failed, [])
        self.assertIn("[WARN]", out)

    def test_host_patterns(self):
        self.assertTrue(cc.host_covered(["istio-system/*.a.io"], "x.a.io"))
        self.assertFalse(cc.host_covered(["*.a.io"], "x.y.b.io"))
        self.assertTrue(cc.host_covered(["*"], "anything"))


class LibTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_virtual_service(self):
        bindir = self.tmp / "bin"
        bindir.mkdir()
        (bindir / "kubectl").write_text(f'#!/bin/sh\n[ "$1" = apply ] && cat > {self.tmp}/vs.yaml\n'
                                        'echo "v1beta1 v1 "\n')
        (bindir / "kubectl").chmod(0o755)
        out = bash("virtual_service cicd-console cicd-console cicd.x.io cicd-console 80 1800s",
                   PATH=f"{bindir}:{os.environ['PATH']}")
        self.assertIn("VirtualService cicd-console/cicd-console", out)
        vs = yaml.safe_load((self.tmp / "vs.yaml").read_text())
        self.assertEqual(vs["apiVersion"], "networking.istio.io/v1")
        self.assertEqual(vs["spec"]["gateways"], ["istio-system/cp-gateway"])
        route = vs["spec"]["http"][0]
        self.assertEqual(route["route"][0]["destination"], {"host": "cicd-console.cicd-console.svc.cluster.local",
                                                            "port": {"number": 80}})
        self.assertEqual(route["timeout"], "1800s")

    def test_drop_ingress(self):
        f = self.tmp / "m.yaml"
        f.write_text("kind: Service\nmetadata: {name: a}\n---\napiVersion: networking.k8s.io/v1\nkind: Ingress\n"
                     "metadata: {name: a}\n---\nkind: Deployment\nmetadata: {name: a}\n")
        bash(f"drop_ingress {f}")
        kinds = [d["kind"] for d in yaml.safe_load_all(f.read_text()) if d]
        self.assertEqual(kinds, ["Service", "Deployment"])

    def test_expose_mode(self):
        self.assertEqual(bash("expose_mode", CICD_EXPOSE="istio").strip(), "istio")
        bindir = self.tmp / "bin"
        bindir.mkdir()
        (bindir / "kubectl").write_text('#!/bin/sh\ncase "$*" in *gateways*) exit 0 ;; *) exit 0 ;; esac\n')
        (bindir / "kubectl").chmod(0o755)
        self.assertEqual(bash("expose_mode", CICD_EXPOSE="auto", PATH=f"{bindir}:{os.environ['PATH']}").strip(), "istio")
        (bindir / "kubectl").write_text('#!/bin/sh\ncase "$*" in *gateways*) exit 1 ;; *) exit 0 ;; esac\n')
        self.assertEqual(bash("expose_mode", CICD_EXPOSE="auto", PATH=f"{bindir}:{os.environ['PATH']}").strip(), "ingress")


def json_pointer(doc, path):
    for part in path.strip("/").split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        doc = doc[int(part)] if isinstance(doc, list) else doc[part]
    return doc


class AppTemplateTest(unittest.TestCase):
    """gitops-template rendered like add-app.sh: the overlay patches point at fields of the base object."""

    def render(self, mode, single=False):
        out = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, out)
        ns_dev, ns_prod = ("soft", "soft") if single else ("soft-dev", "soft-prod")
        svc_dev, svc_prod = ("erp-dev", "erp-prod") if single else ("erp", "erp")
        file, skip = ("virtualservice.yaml", "ingress.yaml") if mode == "istio" else ("ingress.yaml", "virtualservice.yaml")
        bash(f'dev=$(expose_patch {mode} erp erp-soft-dev.x.io {svc_dev}.{ns_dev}.svc.cluster.local); '
             f'prod=$(expose_patch {mode} erp erp-soft.x.io {svc_prod}.{ns_prod}.svc.cluster.local); '
             f'render_tree {SCRIPT_DIR}/../gitops-template {out} APP=erp VENDOR=soft HOST_DOMAIN=x.io '
             f'IMAGE_REPO=h/soft/erp TLS_SECRET=x.io-tls INGRESS_CLASS_NAME=nginx EXPOSE_FILE={file} '
             f'ISTIO_GATEWAY=istio-system/cp-gateway ISTIO_API=networking.istio.io/v1 '
             f'DEV_NAMESPACE={ns_dev} PROD_NAMESPACE={ns_prod} DEV_LAYOUT= PROD_LAYOUT= HEALTH_PATH=/ APP_PORT=8080 '
             f'APP_MEMORY_LIMIT=512Mi PROBES= "DEV_EXPOSE_PATCH=$dev" "PROD_EXPOSE_PATCH=$prod" --exclude {skip} >/dev/null')
        return out

    def check(self, out, kind, file):
        self.assertTrue((out / "base" / file).exists())
        self.assertIn(f"  - {file}", (out / "base/kustomization.yaml").read_text())
        base = yaml.safe_load((out / "base" / file).read_text())
        for env in ("dev", "prod"):
            k = yaml.safe_load((out / "overlays" / env / "kustomization.yaml").read_text())
            p = next(p for p in k["patches"] if p["target"]["kind"] == kind)
            for op in yaml.safe_load(p["patch"]):
                json_pointer(base, op["path"])          # the replaced field exists in the base object
        return base

    def test_istio(self):
        out = self.render("istio")
        self.assertFalse((out / "base/ingress.yaml").exists())
        vs = self.check(out, "VirtualService", "virtualservice.yaml")
        self.assertEqual(vs["spec"]["gateways"], ["istio-system/cp-gateway"])
        dev = (out / "overlays/dev/kustomization.yaml").read_text()
        self.assertIn("value: erp.soft-dev.svc.cluster.local", dev)
        self.assertIn("value: https://erp-soft-dev.x.io", dev)

    def test_istio_single_namespace(self):
        dev = (self.render("istio", single=True) / "overlays/dev/kustomization.yaml").read_text()
        self.assertIn("value: erp-dev.soft.svc.cluster.local", dev)

    def test_ingress(self):
        out = self.render("ingress")
        self.assertFalse((out / "base/virtualservice.yaml").exists())
        ing = self.check(out, "Ingress", "ingress.yaml")
        self.assertEqual(ing["spec"]["ingressClassName"], "nginx")


class ConvertTest(unittest.TestCase):
    """app-expose.sh: an app added with an Ingress becomes a VirtualService app (autoscale patches kept)."""

    def test_ingress_to_virtualservice(self):
        out = AppTemplateTest.render(self, "ingress")
        prod = out / "overlays/prod/kustomization.yaml"
        prod.write_text(prod.read_text() + "  # cicd-portal autoscale begin\n  - target:\n      kind: Deployment\n"
                        "      name: erp\n    patch: |-\n      - op: remove\n        path: /spec/replicas\n"
                        "  # cicd-portal autoscale end\n")
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        (tmp / "dev").write_text(bash("expose_patch istio erp erp-soft-dev.x.io erp.soft-dev.svc.cluster.local"))
        (tmp / "prod").write_text(bash("expose_patch istio erp erp-soft.x.io erp.soft-prod.svc.cluster.local"))
        self.assertTrue(expose_overlay.convert(str(out), "erp", "virtualservice", str(tmp / "dev"), str(tmp / "prod")))
        self.assertIn("  - virtualservice.yaml", (out / "base/kustomization.yaml").read_text())
        self.assertNotIn("ingress.yaml", (out / "base/kustomization.yaml").read_text())
        k = yaml.safe_load(prod.read_text())
        kinds = [p["target"]["kind"] for p in k["patches"]]
        self.assertEqual(kinds, ["VirtualService", "Deployment"])
        self.assertIn("# cicd-portal autoscale begin", prod.read_text())
        self.assertFalse(expose_overlay.convert(str(out), "erp", "virtualservice", str(tmp / "dev"), str(tmp / "prod")))


if __name__ == "__main__":
    unittest.main()
