"""cluster_check.py (deploy-cicd-portal.sh preflight): RKE2 ingress controllers, Pod Security, node pulls."""
import contextlib
import io
import os
import sys
import unittest

sys.path.insert(0, os.environ["CICD_SCRIPT_DIR"])
import cluster_check as cc  # noqa: E402


def pod(ns, owner, kind, image, args=(), host_network=False, host_ip="10.0.0.1", phase="Running", host_ports=False):
    ports = [{"containerPort": 80, "hostPort": 80}] if host_ports else []
    return {"metadata": {"name": f"{owner}-x", "namespace": ns, "ownerReferences": [{"kind": kind, "name": owner}]},
            "spec": {"hostNetwork": host_network,
                     "containers": [{"image": image, "args": list(args), "ports": ports}]},
            "status": {"phase": phase, "hostIP": host_ip}}


RKE2 = pod("kube-system", "rke2-ingress-nginx-controller", "DaemonSet",
           "rancher/nginx-ingress-controller:v1.10.4-hardened3", ["/nginx-ingress-controller"], host_ports=True)
KPAAS = pod("ingress-nginx", "ingress-nginx-controller-5d8849", "ReplicaSet",
            "registry.k8s.io/ingress-nginx/controller:v1.13.3@sha256:x", ["/nginx-ingress-controller", "--ingress-class=nginx"])
LB = {"metadata": {"name": "ingress-nginx-controller", "namespace": "ingress-nginx"},
      "spec": {"type": "LoadBalancer"}, "status": {"loadBalancer": {"ingress": [{"ip": "10.0.0.151"}]}}}
CLASSES = {"items": [{"metadata": {"name": "nginx"}, "spec": {"controller": "k8s.io/ingress-nginx"}}]}


def run(fn, *args, **kwargs):
    cc.FAILED.clear()
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        fn(*args, **kwargs)
    return out.getvalue(), list(cc.FAILED)


class IngressTest(unittest.TestCase):
    def test_controllers(self):
        ctrls = cc.controllers({"items": [RKE2, KPAAS]}, {"items": [LB]})
        self.assertEqual(set(ctrls), {("kube-system", "rke2-ingress-nginx-controller"),
                                      ("ingress-nginx", "ingress-nginx-controller")})
        self.assertEqual(ctrls[("kube-system", "rke2-ingress-nginx-controller")]["ips"], {"10.0.0.1"})
        self.assertEqual(ctrls[("ingress-nginx", "ingress-nginx-controller")]["ips"], {"10.0.0.151"})

    def test_two_controllers_warn(self):
        out, failed = run(cc.check_ingress, "nginx", "keycloak.x", CLASSES, {"items": [RKE2, KPAAS]}, {"items": [LB]},
                          resolve=lambda h: ["10.0.0.151"])
        self.assertIn("2 controllers claim IngressClass nginx", out)
        self.assertIn("rke2-ingress-nginx", out)
        self.assertEqual(failed, [])

    def test_dns_to_wrong_controller_fails(self):
        other = pod("kube-system", "rke2-ingress-nginx-controller", "DaemonSet", "rancher/nginx-ingress-controller:v1",
                    ["/nginx-ingress-controller", "--controller-class=k8s.io/rke2"], host_network=True)
        _, failed = run(cc.check_ingress, "nginx", "keycloak.x", CLASSES, {"items": [other, KPAAS]}, {"items": [LB]},
                        resolve=lambda h: ["10.0.0.1"])
        self.assertTrue(any("does not serve IngressClass nginx" in f for f in failed))

    def test_missing_class_and_dns(self):
        _, failed = run(cc.check_ingress, "traefik", "", CLASSES, {"items": [KPAAS]}, {"items": [LB]})
        self.assertTrue(failed)

        def nxdomain(h):
            raise OSError("Name or service not known")
        _, failed = run(cc.check_ingress, "nginx", "keycloak.x", CLASSES, {"items": [KPAAS]}, {"items": [LB]},
                        resolve=nxdomain)
        self.assertTrue(any("does not resolve" in f for f in failed))


class PodSecurityTest(unittest.TestCase):
    def test_cis_default(self):
        # RKE2 profile: cis -> restricted default; namespaces not created yet
        labels = {"default": {}}
        _, failed = run(cc.check_psa, ["cicd-jenkins"], "baseline", admitted=lambda ns: (False, "violates PodSecurity"),
                        labels=labels)
        self.assertEqual(failed, [])                                    # the install labels it baseline
        _, failed = run(cc.check_psa, ["cicd-jenkins"], "", admitted=lambda ns: (False, "violates"), labels=labels)
        self.assertTrue(failed)

    def test_existing_restricted_label_fails(self):
        labels = {"cicd-jenkins": {cc.PSA_LABEL: "restricted"}}
        out, failed = run(cc.check_psa, ["cicd-jenkins"], "baseline", admitted=lambda ns: (False, "violates"),
                          labels=labels)
        self.assertTrue(failed)
        self.assertIn("--overwrite", out)
        _, failed = run(cc.check_psa, ["cicd-jenkins"], "baseline", admitted=lambda ns: (True, ""),
                        labels={"cicd-jenkins": {}})
        self.assertEqual(failed, [])


class PullTest(unittest.TestCase):
    def test_pull_result(self):
        def st(state, image_id=""):
            return {"status": {"containerStatuses": [{"imageID": image_id, "state": state}]}}
        self.assertEqual(cc.pull_result(st({"terminated": {"exitCode": 0}}, "sha256:x")), "ok")
        self.assertEqual(cc.pull_result(st({"waiting": {"reason": "CreateContainerConfigError"}})), "ok")
        self.assertEqual(cc.pull_result(st({"waiting": {"reason": "ContainerCreating"}})), "pending")
        res = cc.pull_result(st({"waiting": {"reason": "ErrImagePull", "message": "x509: certificate signed by unknown authority"}}))
        self.assertEqual(res[0], "fail")
        self.assertIn("x509", res[1])

    def test_harbor_image_and_probe(self):
        pods = {"items": [pod("cp-portal", "ui", "ReplicaSet", "harbor.x/cp-portal-repository/ui:1"), KPAAS]}
        pods["items"][0]["spec"]["imagePullSecrets"] = [{"name": "cp-secret"}]
        ns, image, secrets = cc.harbor_image(pods, "harbor.x")
        self.assertEqual((ns, image, secrets), ("cp-portal", "harbor.x/cp-portal-repository/ui:1", [{"name": "cp-secret"}]))
        p = cc.probe_pod("p", ns, "node1", image, secrets)
        self.assertEqual(p["spec"]["nodeName"], "node1")
        self.assertEqual(p["spec"]["containers"][0]["imagePullPolicy"], "Always")
        self.assertTrue(p["spec"]["securityContext"]["runAsNonRoot"])      # admitted under "restricted" too

    def test_distro(self):
        nodes = {"items": [{"status": {"nodeInfo": {"kubeletVersion": "v1.30.4+rke2r1"}}}]}
        self.assertEqual(cc.distro(nodes)[0], "rke2")


if __name__ == "__main__":
    unittest.main()
