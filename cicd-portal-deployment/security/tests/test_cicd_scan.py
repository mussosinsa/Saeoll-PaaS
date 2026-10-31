"""Tests of cicd-scan without the scanners installed (report parsers, PII, exceptions, gate).

  cd cicd-portal-deployment/security && python3 -m unittest discover -s tests -v
"""
import contextlib
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "scanner"))
os.environ["CICD_SECURITY_POLICY_DIR"] = str(HERE.parent / "policy")
os.environ["CICD_SECURITY_RULES_DIR"] = str(HERE.parent / "rules")

import cicd_scan  # noqa: E402

# Report formats of gitleaks 8.x (--report-format json --redact) and trivy 0.5x (--format json)
GITLEAKS = [{"Description": "AWS Access Key", "StartLine": 3, "File": "/src/app/config.js", "RuleID": "aws-access-token",
             "Secret": "REDACTED", "Match": "aws_key = REDACTED", "Commit": "", "Fingerprint": "config.js:aws:3"}]
TRIVY = {"SchemaVersion": 2, "ArtifactName": "harbor.x/saeoll/web:dev-1", "Results": [
    {"Target": "package-lock.json", "Class": "lang-pkgs", "Type": "npm", "Vulnerabilities": [
        {"VulnerabilityID": "CVE-2024-0001", "PkgName": "lodash", "InstalledVersion": "4.17.10", "FixedVersion": "4.17.21",
         "Severity": "CRITICAL", "Title": "Prototype pollution", "PrimaryURL": "https://avd.aquasec.com/nvd/cve-2024-0001"},
        {"VulnerabilityID": "CVE-2024-0002", "PkgName": "minimist", "InstalledVersion": "1.2.0", "Severity": "LOW"}]},
    {"Target": "harbor.x/saeoll/web:dev-1 (debian 12.5)", "Class": "os-pkgs", "Vulnerabilities": [
        {"VulnerabilityID": "CVE-2024-0003", "PkgName": "openssl", "InstalledVersion": "3.0.11", "FixedVersion": "3.0.13",
         "Severity": "HIGH", "Title": "openssl issue"}]},
    {"Target": "/app/.env", "Class": "secret", "Secrets": [{"RuleID": "github-pat", "Title": "GitHub PAT", "StartLine": 2}]}]}


class ParserTest(unittest.TestCase):
    def test_gitleaks_no_secret_kept(self):
        found = cicd_scan.parse_gitleaks(GITLEAKS, "/src")
        self.assertEqual(found[0]["file"], "app/config.js")
        self.assertEqual((found[0]["category"], found[0]["severity"]), ("secret", "critical"))
        self.assertNotIn("REDACTED", json.dumps(found))

    def test_trivy(self):
        found = cicd_scan.parse_trivy(TRIVY, "image")
        self.assertEqual([f["severity"] for f in found], ["critical", "low", "high", "critical"])
        self.assertEqual(found[0]["package"], "lodash@4.17.10")
        self.assertIn("수정 버전 4.17.21", found[0]["message"])
        self.assertEqual(found[3]["category"], "secret")

    def test_semgrep_severity(self):
        data = {"results": [{"check_id": "rules.php-eval", "path": "/w/a.php", "start": {"line": 4},
                             "extra": {"severity": "ERROR", "message": "m", "metadata": {"cicd-severity": "critical", "cwe": ["CWE-95"]}}},
                            {"check_id": "x.y", "path": "b.php", "start": {"line": 1}, "extra": {"severity": "INFO", "message": "n"}}]}
        found = cicd_scan.parse_semgrep(data, "/w")
        self.assertEqual([(f["rule"], f["severity"], f["file"]) for f in found],
                         [("php-eval", "critical", "a.php"), ("y", "low", "b.php")])

    def test_validators(self):
        self.assertTrue(cicd_scan.valid_luhn("4111111111111111"))
        self.assertFalse(cicd_scan.valid_luhn("4111111111111112"))
        self.assertTrue(cicd_scan.valid_rrn("9001011234568"))
        self.assertFalse(cicd_scan.valid_rrn("9001011234567"))

    def test_pii_scan(self):
        with tempfile.TemporaryDirectory() as tmp:
            pathlib.Path(tmp, "a.txt").write_text(
                "rrn 900101-1234567\nplain 9001011234567\ncard 4111-1111-1111-1111\nbad 4111-1111-1111-1112\n"
                "M12345678\nx\ny\n여권 M12345678\n")
            pathlib.Path(tmp, "node_modules").mkdir()
            pathlib.Path(tmp, "node_modules", "x.txt").write_text("900101-1234567")
            status, _, found = cicd_scan.scan_pii(tmp, os.path.join(tmp, "security"), {})
        self.assertEqual(status, "ok")
        self.assertEqual([(f["rule"], f["line"]) for f in found], [("kr-rrn", 1), ("card", 3), ("kr-passport", 8)])
        self.assertNotIn("1234567", json.dumps(found))      # masked


class GateTest(unittest.TestCase):
    def run_gate(self, results, policy, env="dev"):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "security")
            os.makedirs(out)
            pdir = os.path.join(tmp, "policy")
            os.makedirs(pdir)
            pathlib.Path(pdir, "policy.json").write_text(json.dumps(policy))
            for tool, findings in results.items():
                cicd_scan.write_result(out, tool, "ok", "", findings)
            with mock.patch.object(cicd_scan, "POLICY_DIRS", [pdir]), \
                    mock.patch.dict(os.environ, {"CICD_APP": "saeoll/web", "CICD_ENV": env, "CICD_APP_TYPE": "node"}), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                rc = cicd_scan.main(["gate", "--out", out])
            with open(os.path.join(out, "summary.json"), encoding="utf-8") as fh:
                return rc, json.load(fh)

    def policy(self, mode="report", exceptions=()):
        return {"gates": {"dev": {"mode": mode, "max": {"critical": 0, "high": -1, "secret": 0, "pii": 0}},
                          "prod": {"mode": "enforce", "max": {"critical": 0, "high": 0}}},
                "profiles": {"default": {"tools": ["trivy-fs", "gitleaks"]}}, "exceptions": list(exceptions)}

    def test_pass_warn_fail(self):
        crit = cicd_scan.parse_trivy(TRIVY, "dependency")[:1]
        rc, s = self.run_gate({"trivy-fs": []}, self.policy())
        self.assertEqual((rc, s["gate"]["result"]), (0, "pass"))
        rc, s = self.run_gate({"trivy-fs": crit}, self.policy())
        self.assertEqual((rc, s["gate"]["result"]), (10, "warn"))
        self.assertEqual(s["gate"]["violations"], [{"key": "critical", "count": 1, "max": 0}])
        rc, s = self.run_gate({"trivy-fs": crit}, self.policy("enforce"))
        self.assertEqual((rc, s["gate"]["result"]), (1, "fail"))
        self.assertEqual(s["counts"]["critical"], 1)

    def test_exceptions(self):
        crit = cicd_scan.parse_trivy(TRIVY, "dependency")[:1]
        approved = {"id": "e1", "app": "saeoll/*", "rule": "trivy-dependency:CVE-2024-0001", "status": "approved"}
        rc, s = self.run_gate({"trivy-fs": crit}, self.policy("enforce", [approved]))
        self.assertEqual((rc, len(s["findings"]), s["suppressed"][0]["exception"]), (0, 0, "e1"))
        for other in (dict(approved, status="requested"), dict(approved, expires="2000-01-01"),
                      dict(approved, app="acme/*"), dict(approved, fingerprint="nope")):
            rc, _ = self.run_gate({"trivy-fs": crit}, self.policy("enforce", [other]))
            self.assertEqual(rc, 1, other)

    def test_secret_and_pii_counts(self):
        secrets = cicd_scan.parse_gitleaks(GITLEAKS)
        pii = [cicd_scan.finding("pii", "kr-mobile", "pii", "medium", "a", 1, "m"),
               cicd_scan.finding("pii", "kr-rrn", "pii", "high", "a", 2, "r")]
        rc, s = self.run_gate({"gitleaks": secrets, "pii": pii}, self.policy())
        self.assertEqual((s["counts"]["secret"], s["counts"]["pii"]), (1, 1))
        self.assertEqual({v["key"] for v in s["gate"]["violations"]}, {"secret", "pii"})

    def test_default_policy_is_valid(self):
        with open(HERE.parent / "policy" / "policy.json", encoding="utf-8") as fh:
            pol = json.load(fh)
        self.assertEqual({g["mode"] for g in pol["gates"].values()}, {"report"})
        with mock.patch.dict(os.environ, {"CICD_APP_TYPE": "java-maven", "CICD_APP": "x/y"}):
            name, prof = cicd_scan.app_profile(pol)
        self.assertEqual((name, prof["semgrep_rules"]), ("java-maven", ["common", "java"]))
        for r in json.load(open(HERE.parent / "rules" / "pii.json", encoding="utf-8")):
            cicd_scan.re.compile(r["regex"])


if __name__ == "__main__":
    unittest.main()
