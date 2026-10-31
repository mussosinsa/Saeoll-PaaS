"""Tests of the 품질 관리 menu (security results, gates, profiles, exceptions, prod sync gate)."""
import copy
import json
import time
import unittest
from unittest import mock

import test_console as t  # sets the environment and the fake vendors / applications

from cicd_console import quality, services

POLICY = {"version": 1,
          "gates": {"dev": {"mode": "report", "max": {"critical": 0, "high": -1, "secret": 0, "pii": 0}},
                    "prod": {"mode": "report", "console_block": True, "max": {"critical": 0, "high": 0}}},
          "profiles": {"default": {"tools": ["semgrep"], "semgrep_rules": ["common"]},
                       "php": {"description": "PHP", "tools": ["semgrep", "gitleaks"], "semgrep_rules": ["common", "php"]}},
          "apps": {}, "exceptions": []}


def summary(result="warn", app="saeoll/homepage"):
    return {"app": app, "env": "dev", "profile": "php", "ref": "develop", "commit": "abc", "image": "h/x:1",
            "generated": "2026-10-31T00:00:00+00:00",
            "counts": {"critical": 1, "high": 2, "medium": 0, "low": 0, "info": 0, "secret": 0, "pii": 0},
            "gate": {"mode": "report", "result": result, "violations": [{"key": "critical", "count": 1, "max": 0}]},
            "tools": {"semgrep": {"status": "ok", "count": 3, "message": "", "version": "1"}}, "missing_tools": [],
            "findings": [{"tool": "semgrep", "rule": "php-eval", "category": "code", "severity": "critical",
                          "file": "src/a.php", "line": 3, "message": "eval 사용", "fingerprint": "f1"},
                         {"tool": "trivy-fs", "rule": "CVE-1", "category": "dependency", "severity": "high",
                          "file": "composer.lock", "line": 0, "message": "lib", "fingerprint": "f2"}],
            "suppressed": []}


FINISHED = [dict(t.BUILDS[0], id="6", number=6, status="success")] + t.BUILDS


class QualityTest(t.ConsoleBase):
    def setUp(self):
        super().setUp()
        self.policy = copy.deepcopy(POLICY)
        self.saved = []
        patches = [
            mock.patch.object(quality, "installed", return_value=True),   # overrides ConsoleBase
            mock.patch.object(quality, "load_policy", side_effect=lambda: (copy.deepcopy(self.policy), "7", "cicd-jenkins")),
            mock.patch.object(quality, "save_policy", side_effect=self._save),
            mock.patch.object(quality, "policy_info", return_value={"by": "", "at": None, "change": ""}),
            mock.patch.object(quality, "build_summary", side_effect=lambda v, a, b: summary(app=f"{v['name']}/{a}") if b else None),
            mock.patch.object(services, "builds", side_effect=lambda v, a, limit=15: FINISHED),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def _save(self, pol, rv, user, note):
        self.assertEqual(rv, "7")
        self.saved.append((pol, user, note))
        self.policy = pol

    def test_issues_and_filters(self):
        self.login("dev1", ["cicd-saeoll"])
        body = self.client.get("/quality/issues").get_data(as_text=True)
        self.assertIn("saeoll/homepage", body)
        self.assertNotIn("acme/shop", body)             # other vendor
        self.assertIn("php-eval", body)
        self.assertIn("예외 요청", body)
        body = self.client.get("/quality/issues?severity=high").get_data(as_text=True)
        self.assertNotIn("php-eval", body)
        self.assertIn("CVE-1", body)

    def test_pages_render(self):
        self.login("admin", ["cicd-admins"])
        rules = {"semgrep": [{"set": "php", "id": "php-eval", "languages": "php", "severity": "high", "message": "m",
                              "cwe": "CWE-95", "description": "eval"}],
                 "gitleaks": {"extend_default": True, "rules": [], "allow_paths": []}, "pii": [], "settings": {},
                 "errors": []}
        with mock.patch.object(quality, "load_rules", return_value=rules):
            for url in ("/quality/rules", "/quality/profiles", "/quality/gates", "/quality/exceptions",
                        "/quality/profiles?edit=php", "/vendors/saeoll/apps/homepage/builds/homepage-dev/7/security",
                        "/"):
                self.assertEqual(self.client.get(url).status_code, 200, url)
        body = self.client.get("/").get_data(as_text=True)
        self.assertIn("보안 게이트 미통과", body)
        body = self.client.get("/vendors/saeoll/apps/homepage").get_data(as_text=True)
        self.assertIn("보안 검사", body)
        self.assertIn("prod Sync (보안 미통과)", body)   # newest release did not pass

    def test_gates_save(self):
        self.login("dev1", ["cicd-saeoll"])
        self.assertEqual(self.post("/quality/gates", {"rv": "7"}).status_code, 403)
        self.login("admin", ["cicd-admins"])
        form = {"rv": "7", "dev.mode": "report", "prod.mode": "enforce", "branch.mode": "report",
                "prod.max.critical": "0", "prod.max.high": "0", "prod.console_block": "on", "dev.max.secret": "0"}
        self.post("/quality/gates", form)
        pol = self.saved[-1][0]
        self.assertEqual(pol["gates"]["prod"]["mode"], "enforce")
        self.assertEqual(pol["gates"]["prod"]["max"]["medium"], -1)
        self.assertTrue(pol["gates"]["prod"]["console_block"])
        self.assertEqual(pol["gates"]["dev"]["max"]["secret"], 0)
        self.post("/quality/gates", dict(form, **{"prod.max.high": "abc"}))
        self.assertEqual(len(self.saved), 1)
        self.post("/quality/gates", dict(form, rv="6"))  # stale page
        self.assertEqual(len(self.saved), 1)

    def test_profiles(self):
        self.login("admin", ["cicd-admins"])
        self.post("/quality/profiles", {"rv": "7", "name": "php-strict", "description": "엄격", "tool.semgrep": "on",
                                        "tool.trivy-image": "on", "set.php": "on", "action": "save"})
        self.assertEqual(self.policy["profiles"]["php-strict"],
                         {"description": "엄격", "tools": ["semgrep", "trivy-image"], "semgrep_rules": ["php"]})
        self.post("/quality/profiles/assign", {"rv": "7", "app": "saeoll/homepage", "profile": "php-strict"})
        self.assertEqual(self.policy["apps"]["saeoll/homepage"], {"profile": "php-strict"})
        self.post("/quality/profiles", {"rv": "7", "name": "php-strict", "action": "delete"})
        self.assertIn("php-strict", self.policy["profiles"])   # still used by an application
        self.post("/quality/profiles", {"rv": "7", "name": "default", "action": "delete"})
        self.assertIn("default", self.policy["profiles"])

    def test_exception_flow(self):
        self.login("dev1", ["cicd-saeoll"])
        req = {"action": "request", "app": "saeoll/homepage", "rule": "semgrep:php-eval", "path": "src/a.php",
               "fingerprint": "f1", "reason": "관리자 전용 계산식 실행, 입력값 검증 완료",
               "expires": time.strftime("%Y-%m-%d", time.localtime(time.time() + 86400 * 30))}
        self.post("/quality/exceptions", req)
        exc = self.policy["exceptions"][-1]
        self.assertEqual((exc["status"], exc["requested_by"], exc["fingerprint"]), ("requested", "dev1", "f1"))
        self.assertEqual(self.post("/quality/exceptions", dict(req, app="acme/shop")).status_code, 403)
        self.post("/quality/exceptions", dict(req, reason="짧음"))
        self.assertEqual(len(self.policy["exceptions"]), 1)
        self.post("/quality/exceptions", dict(req, expires="2099-01-01"))
        self.assertEqual(len(self.policy["exceptions"]), 1)
        self.assertEqual(self.post("/quality/exceptions", {"action": "approve", "id": exc["id"]}).status_code, 403)
        self.login("admin", ["cicd-admins"])
        self.post("/quality/exceptions", {"action": "approve", "id": exc["id"], "note": "확인"})
        self.assertEqual((self.policy["exceptions"][0]["status"], self.policy["exceptions"][0]["approved_by"]),
                         ("approved", "admin"))
        self.post("/quality/exceptions", {"action": "delete", "id": exc["id"]})
        self.assertEqual(self.policy["exceptions"], [])

    def test_prod_sync_gate(self):
        self.login("admin", ["cicd-admins"])
        with mock.patch.object(services, "sync") as sync:
            r = self.post("/vendors/saeoll/apps/homepage/sync", {"env": "prod"})
            self.assertEqual(r.status_code, 302)
            sync.assert_not_called()
            self.post("/vendors/saeoll/apps/homepage/sync", {"env": "prod", "override_reason": "긴급 장애 조치"})
            sync.assert_called_once_with("saeoll-homepage-prod", "admin", None, "긴급 장애 조치")
        with mock.patch.object(quality, "build_summary", side_effect=lambda v, a, b: summary("pass")), \
                mock.patch.object(services, "sync") as sync:
            self.post("/vendors/saeoll/apps/homepage/sync", {"env": "prod"})
            sync.assert_called_once_with("saeoll-homepage-prod", "admin", None, "")
        self.policy["gates"]["prod"]["console_block"] = False
        with mock.patch.object(services, "sync") as sync:
            self.post("/vendors/saeoll/apps/homepage/sync", {"env": "prod"})
            sync.assert_called_once()


class QualityServiceTest(unittest.TestCase):
    def test_load_rules(self):
        cm = {"data": {
            "semgrep-php.yml": "rules:\n  - id: php-eval\n    languages: [php]\n    severity: ERROR\n    message: m\n"
                               "    pattern: eval(...)\n    metadata: {cicd-severity: critical, description: eval}\n",
            "gitleaks.toml": "[extend]\nuseDefault = true\n[[rules]]\nid = \"x\"\ndescription = \"d\"\nregex = '''a+'''\n",
            "pii.json": json.dumps([{"id": "kr-rrn", "name": "주민", "severity": "high", "regex": "x"}]),
            "settings.json": "{}"}}
        with mock.patch.object(quality, "get_json", return_value=cm), \
                mock.patch.object(quality.config, "sources", return_value=["scm"]):
            r = quality.load_rules()
        self.assertEqual(r["semgrep"][0]["severity"], "critical")
        self.assertEqual((r["gitleaks"]["extend_default"], r["gitleaks"]["rules"][0]["id"]), (True, "x"))
        self.assertEqual(r["pii"][0]["id"], "kr-rrn")

    def test_jenkins_summary_cached(self):
        v = {"name": "saeoll", "source": "scm"}
        quality._cache.clear()
        jenkins = mock.Mock(base="https://j", headers={}, path=lambda f, j: f"/job/{f}/job/{j}")
        with mock.patch.object(services, "Jenkins", return_value=jenkins), \
                mock.patch.object(services, "http", return_value=(summary(), {})) as http:
            b = {"job": "homepage-dev", "id": "9", "status": "success"}
            self.assertEqual(quality.build_summary(v, "homepage", b)["gate"]["result"], "warn")
            quality.build_summary(v, "homepage", b)
            self.assertEqual(http.call_count, 1)
            self.assertIn("/job/saeoll/job/homepage-dev/9/artifact/security/summary.json", http.call_args[0][1])
            self.assertIsNone(quality.build_summary(v, "homepage", dict(b, status="running")))

    def test_save_policy_conflict(self):
        with mock.patch.object(quality.config, "sources", return_value=["scm", "gitlab"]), \
                mock.patch.object(quality, "kubectl", side_effect=quality.KubeError(
                    "Operation cannot be fulfilled: the object has been modified")):
            with self.assertRaises(quality.ConflictError):
                quality.save_policy(POLICY, "1", "admin", "x")
        calls = []
        with mock.patch.object(quality.config, "sources", return_value=["scm", "gitlab"]), \
                mock.patch.object(quality, "kubectl", side_effect=lambda *a, **k: calls.append((a, json.loads(k["stdin"])))):
            quality.save_policy(POLICY, "5", "admin", "x")
        self.assertEqual([c[0][0] for c in calls], ["replace", "apply"])
        self.assertEqual(calls[0][1]["metadata"]["resourceVersion"], "5")
        self.assertEqual([c[1]["metadata"]["namespace"] for c in calls], ["cicd-jenkins", "cicd-runner"])


if __name__ == "__main__":
    unittest.main()
