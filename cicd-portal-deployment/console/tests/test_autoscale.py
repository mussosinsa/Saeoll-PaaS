"""자동 확장 (HPA): autoscale_overlay.py (gitops overlay), services.autoscalers, 설정 화면 -> scale-app.sh."""
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

import yaml

import test_console as t

from cicd_console import jobs, services

sys.path.insert(0, os.environ["CICD_SCRIPT_DIR"])
import autoscale_overlay as ov  # noqa: E402

TEMPLATE = os.path.join(os.environ["CICD_SCRIPT_DIR"], "..", "gitops-template", "overlays", "prod", "kustomization.yaml")


class OverlayTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        text = open(TEMPLATE, encoding="utf-8").read()
        for k, v in {"{APP}": "erp", "{VENDOR}": "soft", "{HOST_DOMAIN}": "x.io", "{PROD_NAMESPACE}": "soft",
                     "{PROD_LAYOUT}": "nameSuffix: -prod\n", "{IMAGE_REPO}": "h/soft/erp"}.items():
            text = text.replace(k, v)
        self.kfile = os.path.join(self.dir, "kustomization.yaml")
        with open(self.kfile, "w", encoding="utf-8") as fh:
            fh.write(text)
        self.orig = text

    def kustomization(self):
        return yaml.safe_load(self.text())

    def text(self):
        with open(self.kfile, encoding="utf-8") as fh:
            return fh.read()

    def test_enable_disable_roundtrip(self):
        info = ov.enable(self.dir, "erp", 2, 6, 70, 0, "300m", True)
        self.assertEqual((info["min"], info["max"], info["cpu"], info["cpu_request"], info["sticky"]),
                         (2, 6, 70, "300m", True))
        k = self.kustomization()
        self.assertIn("autoscale.yaml", k["resources"])
        self.assertNotIn("replicas", k)                               # the HPA owns the count
        dep = next(p for p in k["patches"] if p["target"]["kind"] == "Deployment")
        ops = yaml.safe_load(dep["patch"])
        self.assertEqual(ops[0], {"op": "remove", "path": "/spec/replicas"})
        self.assertEqual(ops[1]["value"], "300m")
        with open(os.path.join(self.dir, "autoscale.yaml"), encoding="utf-8") as fh:
            docs = list(yaml.safe_load_all(fh))
        self.assertEqual([d["kind"] for d in docs], ["HorizontalPodAutoscaler", "PodDisruptionBudget"])
        self.assertEqual(docs[0]["spec"]["scaleTargetRef"]["name"], "erp")
        ov.enable(self.dir, "erp", 3, 8, 60, 0, "200m", False)        # change: one block, no sticky
        self.assertEqual(self.text().count(ov.BEGIN), 1)
        self.assertEqual(len(self.kustomization()["patches"]), 2)
        self.assertEqual(ov.disable(self.dir, "erp"), 2)
        self.assertEqual(self.text(), self.orig)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "autoscale.yaml")))

    def test_stop_start(self):
        ov.enable(self.dir, "erp", 2, 6, 70, 0, "200m", False)
        self.assertEqual(ov.set_stopped(self.dir, True), 0)
        ops = yaml.safe_load(next(p for p in self.kustomization()["patches"] if p["target"]["kind"] == "Deployment")["patch"])
        self.assertEqual(ops[0], {"op": "replace", "path": "/spec/replicas", "value": 0})
        self.assertTrue(ov.status(self.dir, "erp")["stopped"])
        self.assertEqual(ov.set_stopped(self.dir, False), 2)           # start: scale to minReplicas
        self.assertFalse(ov.status(self.dir, "erp")["stopped"])
        ov.set_stopped(self.dir, True)
        ov.disable(self.dir, "erp")                                     # off while stopped: stays stopped
        self.assertEqual(self.kustomization()["replicas"], [{"name": "erp", "count": 0}])

    def test_limits(self):
        for args in ((0, 6, 70, 0, "200m"), (5, 4, 70, 0, "200m"), (2, 6, 99, 0, "200m"), (2, 6, 70, 0, "lots")):
            with self.assertRaises(ov.OverlayError):
                ov.enable(self.dir, "erp", *args, False)


HPA = {"items": [{"metadata": {"namespace": "saeoll-homepage", "name": "homepage"},
                  "spec": {"minReplicas": 2, "maxReplicas": 4, "metrics": [
                      {"type": "Resource", "resource": {"name": "cpu", "target": {"type": "Utilization", "averageUtilization": 70}}}]},
                  "status": {"currentReplicas": 4, "desiredReplicas": 4, "currentMetrics": [
                      {"type": "Resource", "resource": {"name": "cpu", "current": {"averageUtilization": 93}}}],
                      "conditions": [{"type": "ScalingLimited", "status": "True", "reason": "TooManyReplicas",
                                      "message": "the desired replica count is more than the maximum replica count"}]}}]}


class AutoscaleConsoleTest(t.ConsoleBase):
    def setUp(self):
        super().setUp()
        mock.patch.object(services, "get_json", return_value=HPA).start()
        self.start = mock.patch.object(jobs, "start", return_value=mock.Mock(id="8")).start()
        self.addCleanup(mock.patch.stopall)

    def test_status(self):
        hpas = services.autoscalers()
        self.assertEqual(hpas[("saeoll-homepage", "homepage")]["cpu"], 93)
        self.assertTrue(hpas[("saeoll-homepage", "homepage")]["at_max"])
        self.login("dev1", ["cicd-saeoll"])
        body = self.client.get("/vendors/saeoll/apps/homepage").get_data(as_text=True)
        self.assertIn("최대 도달", body)
        self.assertIn("×4", self.client.get("/vendors/saeoll").get_data(as_text=True))   # card badge
        self.assertNotIn("/autoscale", body)                       # settings: operators only
        self.assertEqual(self.client.get("/vendors/saeoll/apps/homepage/autoscale").status_code, 403)
        self.login("admin", ["cicd-admins"])
        self.assertIn("자동 확장 최대 도달", self.client.get("/").get_data(as_text=True))

    def test_settings(self):
        self.login("admin", ["cicd-admins"])
        quota = [{"name": "requests.cpu", "used": "1", "hard": "4"}, {"name": "pods", "used": "3", "hard": "30"}]
        with mock.patch.object(services, "namespace_quota", return_value=quota):
            body = self.client.get("/vendors/saeoll/apps/homepage/autoscale?env=prod").get_data(as_text=True)
            self.assertIn('value="4"', body)                         # current max from the HPA
            r = self.post("/vendors/saeoll/apps/homepage/autoscale",
                          {"env": "prod", "action": "on", "min": "2", "max": "10", "cpu": "70", "memory": "0",
                           "cpu_request": "500m"})
            self.assertIn("쿼터", r.get_data(as_text=True))           # 10 x 500m > 4 CPU
            self.start.assert_not_called()
            self.post("/vendors/saeoll/apps/homepage/autoscale",
                      {"env": "prod", "action": "on", "min": "2", "max": "6", "cpu": "70", "memory": "0",
                       "cpu_request": "300m", "sticky": "on", "reason": "신청 기간 대비"})
        args, kwargs = self.start.call_args
        self.assertEqual((args[1], args[2]), ("scale-app.sh", ["saeoll", "homepage", "prod", "on"]))
        self.assertEqual({k: kwargs["env"][k] for k in ("MIN", "MAX", "CPU_TARGET", "CPU_REQUEST", "STICKY")},
                         {"MIN": "2", "MAX": "6", "CPU_TARGET": "70", "CPU_REQUEST": "300m", "STICKY": "1"})
        self.post("/vendors/saeoll/apps/homepage/autoscale", {"env": "prod", "action": "off"})
        self.assertEqual(self.start.call_args.args[2], ["saeoll", "homepage", "prod", "off"])


if __name__ == "__main__":
    unittest.main()
