#!/usr/bin/env python3
"""cicd-scan: security checks of the CI/CD portal pipelines (Jenkins and GitLab CI).

  cicd-scan source [--dir .] [--out security]   code (Semgrep), secrets (Gitleaks), dependencies (Trivy fs),
                                                personal information (built-in Korean patterns, Presidio)
  cicd-scan image --image <ref> [--out security] container image (Trivy image)
  cicd-scan gate [--out security]                merge results, apply exceptions and the gate of the policy,
                                                write <out>/summary.json; exit 0 pass, 10 warn (report mode), 1 fail
  cicd-scan upload [--out security]              send the raw reports to DefectDojo (optional)

Settings: /etc/cicd-security/policy/policy.json (ConfigMap cicd-security-policy, edited in the CI/CD console),
          /etc/cicd-security/rules/ (ConfigMap cicd-security-rules: Semgrep rules, gitleaks.toml, pii.json,
          settings.json); the copies baked into the image (/opt/cicd-security) are used when they are missing.
Pipeline environment: CICD_APP (<vendor>/<app>), CICD_ENV (dev|prod|branch), CICD_APP_TYPE, CICD_REF,
          CICD_COMMIT, CICD_BUILD_URL, CICD_CA_FILE (K-PaaS CA), TRIVY_USERNAME/TRIVY_PASSWORD (Harbor robot).
Secrets and personal information are never written to the reports in clear text.
"""
import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

ENV = os.environ
POLICY_DIRS = [ENV.get("CICD_SECURITY_POLICY_DIR", "/etc/cicd-security/policy"), "/opt/cicd-security/policy"]
RULE_DIRS = [ENV.get("CICD_SECURITY_RULES_DIR", "/etc/cicd-security/rules"), "/opt/cicd-security/rules"]
SEVERITIES = ["critical", "high", "medium", "low", "info"]
SKIP_DIRS = {".git", "vendor", "node_modules", "build", "target", "dist", ".gradle", ".composer-cache", ".m2",
             ".npm", ".cache", "__pycache__", ".venv", "venv", "coverage"}
MAX_FILE_BYTES = 1024 * 1024
TOOL_TIMEOUT = int(ENV.get("CICD_SCAN_TIMEOUT", "900"))


def log(msg):
    print(f"[cicd-scan] {msg}", file=sys.stderr, flush=True)


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


# ------------------------------------------------------------------ settings ---
def find_file(dirs, name):
    for d in dirs:
        path = os.path.join(d, name)
        if os.path.isfile(path):
            return path
    return None


def load_json(dirs, name, default):
    path = find_file(dirs, name)
    if not path:
        return default
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as e:
        log(f"WARN {path} is not valid JSON ({e}) - using defaults")
        return default


def policy():
    return load_json(POLICY_DIRS, "policy.json", {})


def settings():
    return load_json(RULE_DIRS, "settings.json", {})


def app_profile(pol):
    """Profile of the application: policy.apps[<vendor>/<app>].profile, else the profile named after the
    application type (php, node, ...), else 'default'."""
    profiles = pol.get("profiles") or {}
    app = ENV.get("CICD_APP", "")
    name = ((pol.get("apps") or {}).get(app) or {}).get("profile") or ENV.get("CICD_APP_TYPE", "")
    if name not in profiles:
        name = "default"
    prof = dict(profiles.get(name) or {})
    prof.setdefault("tools", ["semgrep", "gitleaks", "trivy-fs", "pii", "trivy-image"])
    prof.setdefault("semgrep_rules", ["common"])
    return name, prof


def ca_bundle():
    """System CAs + the K-PaaS CA (Harbor, Presidio, DefectDojo behind the platform ingress)."""
    extra = ENV.get("CICD_CA_FILE", "/etc/cicd-ca/ca.crt")
    if not os.path.isfile(extra):
        return None
    target = "/tmp/cicd-scan-ca.crt"
    with open(target, "w", encoding="utf-8") as out:
        for path in ("/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", extra):
            if os.path.isfile(path):
                with open(path, encoding="utf-8", errors="replace") as fh:
                    out.write(fh.read().rstrip() + "\n")
    return target


def run(cmd, out_file=None, env=None, ok_codes=(0,)):
    """Run a tool; returns (status, message). The tool's exit code for 'findings present' is passed in ok_codes."""
    log("$ " + " ".join(cmd))
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TOOL_TIMEOUT, env=env)
    except FileNotFoundError:
        return "error", f"{cmd[0]} is not installed"
    except subprocess.TimeoutExpired:
        return "error", f"{cmd[0]} timed out after {TOOL_TIMEOUT}s"
    if out_file and proc.stdout and not os.path.exists(out_file):
        with open(out_file, "w", encoding="utf-8") as fh:
            fh.write(proc.stdout)
    if proc.returncode not in ok_codes:
        tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-5:]
        return "error", f"exit {proc.returncode}: " + " | ".join(tail)
    return "ok", ""


def fingerprint(*parts):
    return hashlib.sha256("|".join(str(p) for p in parts).encode()).hexdigest()[:16]


def finding(tool, rule, category, severity, file="", line=0, message="", **extra):
    severity = severity if severity in SEVERITIES else "medium"
    f = {"tool": tool, "rule": rule, "category": category, "severity": severity, "file": file or "",
         "line": int(line or 0), "message": (message or "").strip()[:500]}
    f.update({k: v for k, v in extra.items() if v not in (None, "")})
    f["fingerprint"] = fingerprint(tool, rule, f["file"], extra.get("key") or f["message"])
    f.pop("key", None)
    return f


def write_result(out, tool, status, message, findings, version=""):
    with open(os.path.join(out, f"result-{tool}.json"), "w", encoding="utf-8") as fh:
        json.dump({"tool": tool, "status": status, "message": message, "version": version,
                   "count": len(findings), "findings": findings}, fh, ensure_ascii=False, indent=1)
    log(f"{tool}: {status} {len(findings)} finding(s) {message}")


def tool_version(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip().splitlines()[0][:60]
    except (OSError, IndexError, subprocess.TimeoutExpired):
        return ""


def mask(value):
    value = str(value)
    if len(value) <= 4:
        return "*" * len(value)
    keep = max(2, len(value) // 5)
    return value[:keep] + "*" * (len(value) - keep * 2) + value[-keep:]


# ------------------------------------------------------------------ Semgrep ---
SEMGREP_SEVERITY = {"ERROR": "high", "WARNING": "medium", "INFO": "low"}


def relpath(path, src):
    if path and src and os.path.isabs(path):
        try:
            return os.path.relpath(path, src)
        except ValueError:
            return path
    return path


def parse_semgrep(data, src=""):
    result = []
    for r in data.get("results") or []:
        extra = r.get("extra") or {}
        meta = extra.get("metadata") or {}
        sev = str(meta.get("cicd-severity") or SEMGREP_SEVERITY.get(extra.get("severity"), "medium")).lower()
        cwe = meta.get("cwe")
        result.append(finding("semgrep", r.get("check_id", "").split(".")[-1] or r.get("check_id", ""), "code", sev,
                              relpath(r.get("path"), src), (r.get("start") or {}).get("line"), extra.get("message"),
                              cwe=", ".join(cwe) if isinstance(cwe, list) else cwe,
                              key=f"{(extra.get('lines') or '').strip()}|{extra.get('message')}"))
    return result


def scan_semgrep(src, out, prof):
    configs = []
    for name in prof.get("semgrep_rules") or []:
        path = find_file(RULE_DIRS, f"semgrep-{name}.yml")
        if path:
            configs += ["--config", path]
        else:
            log(f"WARN Semgrep rule set '{name}' not found")
    if not configs:
        return "skipped", "no Semgrep rules", []
    raw = os.path.join(out, "semgrep.json")
    cmd = ["semgrep", "scan", "--json", "--quiet", "--metrics=off", "--disable-version-check", "--no-git-ignore",
           "--timeout", "30", "--max-target-bytes", str(MAX_FILE_BYTES), "--output", raw, *configs]
    for d in sorted(SKIP_DIRS | {os.path.basename(os.path.abspath(out))}):
        cmd += ["--exclude", d]
    status, msg = run(cmd + [src], ok_codes=(0, 1))
    if not os.path.isfile(raw):
        return "error", msg or "no Semgrep report", []
    with open(raw, encoding="utf-8") as fh:
        data = json.load(fh)
    errors = [e for e in data.get("errors") or [] if e.get("level") == "error"]
    if errors and status == "ok":
        msg = f"{len(errors)} file(s) could not be parsed"
    return status, msg, parse_semgrep(data, src)


# ----------------------------------------------------------------- Gitleaks ---
def parse_gitleaks(data, src=""):
    result = []
    for r in data or []:
        secret = r.get("Secret") or ""
        result.append(finding("gitleaks", r.get("RuleID", "secret"), "secret", "critical", relpath(r.get("File"), src),
                              r.get("StartLine"), r.get("Description") or "비밀정보 노출",
                              commit=(r.get("Commit") or "")[:12],
                              key=hashlib.sha256(secret.encode()).hexdigest() if secret and secret != "REDACTED"
                              else f"{r.get('Match')}|{r.get('StartLine')}"))
    return result


def scan_gitleaks(src, out, prof):
    raw = os.path.join(out, "gitleaks.json")
    cmd = ["gitleaks", "git" if prof.get("gitleaks_history") else "dir", src, "--redact", "--no-banner",
           "--report-format", "json", "--report-path", raw, "--exit-code", "0", "--log-level", "warn"]
    config = find_file(RULE_DIRS, "gitleaks.toml")
    if config:
        cmd += ["--config", config]
    status, msg = run(cmd)
    if status != "ok":
        return status, msg, []
    with open(raw, encoding="utf-8") as fh:
        data = json.load(fh)
    found = [f for f in parse_gitleaks(data, src) if not _skipped_path(f["file"])]
    for f in found:   # scrub what gitleaks keeps of the match (only the redacted secret is written)
        f.pop("match", None)
    return status, msg, found


def _skipped_path(path):
    parts = (path or "").replace("\\", "/").split("/")
    return any(p in SKIP_DIRS for p in parts[:-1])


# -------------------------------------------------------------------- Trivy ---
def parse_trivy(data, category):
    result = []
    for res in (data or {}).get("Results") or []:
        target = res.get("Target") or ""
        for v in res.get("Vulnerabilities") or []:
            pkg = f"{v.get('PkgName')}@{v.get('InstalledVersion')}"
            fixed = v.get("FixedVersion") or ""
            msg = f"{pkg}: {v.get('Title') or v.get('VulnerabilityID')}" + (f" (수정 버전 {fixed})" if fixed else " (수정 버전 없음)")
            result.append(finding(f"trivy-{category}", v.get("VulnerabilityID", ""), category,
                                  str(v.get("Severity", "unknown")).lower().replace("unknown", "info"), target, 0, msg,
                                  package=pkg, fixed=fixed, url=v.get("PrimaryURL"),
                                  key=f"{v.get('VulnerabilityID')}|{pkg}"))
        for s in res.get("Secrets") or []:   # trivy image secret scanning (only for images)
            result.append(finding(f"trivy-{category}", s.get("RuleID", "secret"), "secret", "critical",
                                  target, s.get("StartLine"), s.get("Title") or "이미지 안의 비밀정보",
                                  key=f"{s.get('RuleID')}|{target}|{s.get('StartLine')}"))
    return result


def trivy_env():
    env = dict(ENV)
    bundle = ca_bundle()
    if bundle:
        env["SSL_CERT_FILE"] = bundle
    st = settings().get("trivy") or {}
    for key, var in (("db_repository", "TRIVY_DB_REPOSITORY"), ("java_db_repository", "TRIVY_JAVA_DB_REPOSITORY")):
        if st.get(key):
            env.setdefault(var, st[key])
    env.setdefault("TRIVY_CACHE_DIR", ENV.get("TRIVY_CACHE_DIR", "/opt/trivy-cache"))
    env.setdefault("TRIVY_NO_PROGRESS", "true")
    return env


def run_trivy(args, raw):
    """Trivy with a DB update; when the update fails (closed network) retry with the DB baked into the image."""
    env = trivy_env()
    base = ["trivy", *args, "--format", "json", "--output", raw, "--exit-code", "0", "--quiet"]
    status, msg = run(base, env=env)
    if status != "ok" and ("download" in msg.lower() or "db" in msg.lower() or "fetch" in msg.lower()):
        log("Trivy DB update failed - retrying with the DB in the image (--skip-db-update)")
        status, msg = run(base + ["--skip-db-update", "--skip-java-db-update"], env=env)
        if status == "ok":
            msg = "offline DB used (update failed)"
    return status, msg


def scan_trivy_fs(src, out, prof):
    raw = os.path.join(out, "trivy-fs.json")
    status, msg = run_trivy(["fs", "--scanners", "vuln", "--skip-dirs", "node_modules", "--skip-dirs", "vendor", src], raw)
    if not os.path.isfile(raw):
        return "error" if status != "ok" else status, msg, []
    with open(raw, encoding="utf-8") as fh:
        found = parse_trivy(json.load(fh), "dependency")
    for f in found:
        f["file"] = relpath(f["file"], src)
    return status, msg, found


def scan_image(image, out):
    raw = os.path.join(out, "trivy-image.json")
    status, msg = run_trivy(["image", "--scanners", "vuln,secret", image], raw)
    if not os.path.isfile(raw):
        return "error" if status != "ok" else status, msg, []
    with open(raw, encoding="utf-8") as fh:
        return status, msg, parse_trivy(json.load(fh), "image")


# ------------------------------------------------- personal information (PII) ---
def valid_rrn(digits):
    """Resident registration number checksum (numbers issued before Oct 2020)."""
    d = [int(c) for c in digits]
    weights = [2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5]
    return (11 - sum(a * b for a, b in zip(d[:12], weights)) % 11) % 10 == d[12]


def valid_luhn(digits):
    total = 0
    for i, c in enumerate(reversed(digits)):
        n = int(c)
        if i % 2:
            n = n * 2 - 9 if n > 4 else n * 2
        total += n
    return total % 10 == 0


def pii_rules():
    rules = load_json(RULE_DIRS, "pii.json", [])
    for r in rules:
        r["_re"] = re.compile(r["regex"])
    return rules


def pii_match_ok(rule, text, lines, idx):
    digits = re.sub(r"\D", "", text)
    v = rule.get("validator")
    if v == "rrn" and "-" not in text and not valid_rrn(digits):
        return False      # 13 digits without a hyphen: only numbers with a valid checksum
    if v == "luhn" and not valid_luhn(digits):
        return False
    ctx = rule.get("context")
    if ctx:
        near = " ".join(lines[max(0, idx - 1): idx + 2]).lower()
        return any(word.lower() in near for word in ctx)
    return True


def text_files(src, out=None):
    skip_out = os.path.abspath(out) if out else None
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and os.path.abspath(os.path.join(root, d)) != skip_out]
        for name in files:
            if name.endswith((".min.js", ".lock", "-lock.json", ".map", ".svg")) or name in ("go.sum",):
                continue
            path = os.path.join(root, name)
            try:
                if os.path.getsize(path) > MAX_FILE_BYTES:
                    continue
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            if b"\0" in data[:8192]:
                continue
            yield os.path.relpath(path, src), data.decode("utf-8", errors="replace")


def scan_pii(src, out, prof):
    rules = pii_rules()
    if not rules:
        return "skipped", "pii.json not found", []
    result = []
    for rel, text in text_files(src, out):
        lines = text.splitlines()
        for idx, line in enumerate(lines):
            for r in rules:
                for m in r["_re"].finditer(line):
                    if pii_match_ok(r, m.group(0), lines, idx):
                        result.append(finding("pii", r["id"], "pii", r.get("severity", "high"), rel, idx + 1,
                                              f"{r.get('name', r['id'])} 의심: {mask(m.group(0))}",
                                              key=hashlib.sha256(m.group(0).encode()).hexdigest()))
    return "ok", "", result


def scan_presidio(src, out, prof):
    """Presidio analyzer (phase 4): context-aware detection; Korean patterns are sent as ad-hoc recognizers
    and checked again with the local validators."""
    url = (settings().get("presidio") or {}).get("url") or ENV.get("PRESIDIO_URL", "")
    if not url:
        return "skipped", "Presidio is not deployed (SECURITY_PRESIDIO=true ./deploy-cicd-portal.sh security)", []
    rules = pii_rules()
    adhoc = [{"name": f"cicd-{r['id']}", "supported_language": "en", "supported_entity": r["id"].upper(),
              "patterns": [{"name": r["id"], "regex": r["regex"], "score": 0.6}], "context": r.get("context") or []}
             for r in rules]
    by_entity = {r["id"].upper(): r for r in rules}
    entities = [*by_entity, *((settings().get("presidio") or {}).get("entities") or
                              ["CREDIT_CARD", "EMAIL_ADDRESS", "IBAN_CODE", "IP_ADDRESS"])]
    threshold = float((settings().get("presidio") or {}).get("score_threshold", 0.5))
    result, errors, sent = [], 0, 0
    budget = int((settings().get("presidio") or {}).get("max_bytes", 5 * MAX_FILE_BYTES))
    bundle = ca_bundle()
    ctx = None
    if bundle and url.startswith("https"):
        import ssl  # noqa: PLC0415
        ctx = ssl.create_default_context(cafile=bundle)
    for rel, text in text_files(src, out):
        if sent > budget:
            log("Presidio byte budget reached - remaining files not sent")
            break
        sent += len(text)
        body = json.dumps({"text": text, "language": "en", "entities": entities, "score_threshold": threshold,
                           "ad_hoc_recognizers": adhoc}).encode()
        req = urllib.request.Request(url.rstrip("/") + "/analyze", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60, context=ctx) as resp:
                items = json.loads(resp.read().decode() or "[]")
        except (urllib.error.URLError, OSError, ValueError) as e:
            errors += 1
            if errors >= 3:
                return "error", f"Presidio {url}: {getattr(e, 'reason', e)}", result
            continue
        lines = text.splitlines()
        offsets, pos = [], 0
        for ln in lines:
            offsets.append(pos)
            pos += len(ln) + 1
        for it in items:
            value = text[it["start"]:it["end"]]
            line_no = max(i for i, o in enumerate(offsets) if o <= it["start"]) + 1 if offsets else 1
            rule = by_entity.get(it["entity_type"])
            if rule and not pii_match_ok(rule, value, lines, line_no - 1):
                continue
            sev = rule.get("severity", "high") if rule else ("high" if it["entity_type"] == "CREDIT_CARD" else "low")
            result.append(finding("presidio", it["entity_type"].lower(), "pii", sev, rel, line_no,
                                  f"{(rule or {}).get('name', it['entity_type'])} 의심 (score {it.get('score', 0):.2f}): {mask(value)}",
                                  key=hashlib.sha256(value.encode()).hexdigest()))
    return "ok", "", result


# ------------------------------------------------------------------- commands ---
SOURCE_TOOLS = {"semgrep": (scan_semgrep, ["semgrep", "--version"]),
                "gitleaks": (scan_gitleaks, ["gitleaks", "version"]),
                "trivy-fs": (scan_trivy_fs, ["trivy", "--version"]),
                "pii": (scan_pii, None),
                "presidio": (scan_presidio, None)}


def cmd_source(a):
    os.makedirs(a.out, exist_ok=True)
    name, prof = app_profile(policy())
    log(f"profile {name}: {', '.join(prof['tools'])}")
    for tool in prof["tools"]:
        if tool not in SOURCE_TOOLS:
            continue
        fn, vcmd = SOURCE_TOOLS[tool]
        try:
            status, msg, found = fn(os.path.abspath(a.dir), a.out, prof)
        except Exception as e:  # noqa: BLE001 - one broken tool must not stop the others
            status, msg, found = "error", f"{type(e).__name__}: {e}", []
        write_result(a.out, tool, status, msg, found, tool_version(vcmd) if vcmd and status != "skipped" else "")
    return 0


def cmd_image(a):
    os.makedirs(a.out, exist_ok=True)
    _, prof = app_profile(policy())
    if "trivy-image" not in prof["tools"]:
        log("trivy-image is not in the profile - skipped")
        return 0
    try:
        status, msg, found = scan_image(a.image, a.out)
    except Exception as e:  # noqa: BLE001
        status, msg, found = "error", f"{type(e).__name__}: {e}", []
    write_result(a.out, "trivy-image", status, msg, found, tool_version(["trivy", "--version"]))
    return 0


def exception_matches(exc, app, f):
    if exc.get("status", "approved") != "approved":
        return False
    expires = exc.get("expires")
    if expires and expires < datetime.date.today().isoformat():
        return False
    if not fnmatch.fnmatch(app, exc.get("app") or "*"):
        return False
    if exc.get("fingerprint"):
        return exc["fingerprint"] == f["fingerprint"]
    return (fnmatch.fnmatch(f"{f['tool']}:{f['rule']}", exc.get("rule") or "*")
            and fnmatch.fnmatch(f["file"], exc.get("path") or "*"))


def evaluate(findings, gate):
    """Counts per severity (code, dependency, image) and per category (secret, pii) against gate.max."""
    counts = {s: 0 for s in SEVERITIES}
    counts.update(secret=0, pii=0)
    for f in findings:
        if f["category"] == "secret":
            counts["secret"] += 1
        elif f["category"] == "pii":
            if f["severity"] in ("critical", "high"):
                counts["pii"] += 1
        else:
            counts[f["severity"]] += 1
    violations = []
    for key, limit in (gate.get("max") or {}).items():
        if limit is not None and int(limit) >= 0 and counts.get(key, 0) > int(limit):
            violations.append({"key": key, "count": counts.get(key, 0), "max": int(limit)})
    return counts, violations


def cmd_gate(a):
    os.makedirs(a.out, exist_ok=True)
    pol = policy()
    app = ENV.get("CICD_APP", "")
    env_name = ENV.get("CICD_ENV", "dev")
    gates = pol.get("gates") or {}
    gate = gates.get(env_name) or gates.get("dev") or {"mode": "report", "max": {}}
    profile_name, prof = app_profile(pol)
    tools, findings, suppressed = {}, [], []
    for name in sorted(os.listdir(a.out)):
        if not (name.startswith("result-") and name.endswith(".json")):
            continue
        with open(os.path.join(a.out, name), encoding="utf-8") as fh:
            res = json.load(fh)
        tools[res["tool"]] = {k: res.get(k) for k in ("status", "message", "version", "count")}
        for f in res.get("findings") or []:
            exc = next((e for e in pol.get("exceptions") or [] if exception_matches(e, app, f)), None)
            if exc:
                suppressed.append(dict(f, exception=exc.get("id", "")))
            else:
                findings.append(f)
    order = {s: i for i, s in enumerate(SEVERITIES)}
    findings.sort(key=lambda f: (order.get(f["severity"], 9), f["category"], f["file"], f["line"]))
    counts, violations = evaluate(findings, gate)
    tool_errors = [t for t, r in tools.items() if r["status"] == "error"]
    if gate.get("fail_on_tool_error") and tool_errors:
        violations.append({"key": "tool_error", "count": len(tool_errors), "max": 0})
    expected = [t for t in prof["tools"] if t in SOURCE_TOOLS or t == "trivy-image"]
    missing = [t for t in expected if t not in tools and not (t == "trivy-image" and not ENV.get("CICD_IMAGE"))]
    mode = gate.get("mode", "report")
    result = "pass" if not violations else ("fail" if mode == "enforce" else "warn")
    summary = {
        "version": 1, "app": app, "env": env_name, "type": ENV.get("CICD_APP_TYPE", ""),
        "ref": ENV.get("CICD_REF", ""), "commit": ENV.get("CICD_COMMIT", ""), "image": ENV.get("CICD_IMAGE", ""),
        "build_url": ENV.get("CICD_BUILD_URL", ""), "generated": now(), "profile": profile_name,
        "tools": tools, "missing_tools": missing, "counts": counts,
        "gate": {"mode": mode, "result": result, "max": gate.get("max") or {}, "violations": violations},
        "findings": findings[:2000], "truncated": max(0, len(findings) - 2000), "suppressed": suppressed[:500],
    }
    with open(os.path.join(a.out, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=1)
    print_summary(summary)
    return {"pass": 0, "warn": 10}.get(result, 1)


def print_summary(s):
    label = {"pass": "통과", "warn": "경고 (기준 초과, 경고 모드)", "fail": "실패 (배포 차단)"}[s["gate"]["result"]]
    c = s["counts"]
    print("=" * 72)
    print(f"보안 검사 {s['app']} [{s['env']}] 프로파일 {s['profile']} - 게이트: {label}")
    print(f"  critical {c['critical']}  high {c['high']}  medium {c['medium']}  low {c['low']}"
          f"  | 비밀정보 {c['secret']}  개인정보 {c['pii']}  | 예외 처리 {len(s['suppressed'])}")
    for t, r in s["tools"].items():
        print(f"  - {t:12} {r['status']:8} {r['count']:4}건 {r.get('message') or ''}")
    for v in s["gate"]["violations"]:
        print(f"  ! {v['key']}: {v['count']}건 (허용 {v['max']}건)")
    for f in s["findings"][:20]:
        print(f"  [{f['severity']:8}] {f['tool']}:{f['rule']} {f['file']}:{f['line']} {f['message'][:120]}")
    if len(s["findings"]) > 20:
        print(f"  ... 외 {len(s['findings']) - 20}건 - CI/CD 콘솔 품질 관리 > 보안 이슈")
    print("=" * 72)


# ------------------------------------------------------------------ DefectDojo ---
DOJO_SCAN_TYPES = {"semgrep.json": "Semgrep JSON Report", "gitleaks.json": "Gitleaks Scan",
                   "trivy-fs.json": "Trivy Scan", "trivy-image.json": "Trivy Scan"}


def multipart(fields, files):
    boundary = uuid.uuid4().hex
    body = b""
    for k, v in fields.items():
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n").encode()
    for k, (name, data) in files.items():
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"; filename=\"{name}\"\r\n"
                 "Content-Type: application/json\r\n\r\n").encode() + data + b"\r\n"
    return body + f"--{boundary}--\r\n".encode(), f"multipart/form-data; boundary={boundary}"


def cmd_upload(a):
    url, token = ENV.get("DEFECTDOJO_URL", "").rstrip("/"), ENV.get("DEFECTDOJO_TOKEN", "")
    if not (url and token):
        log("DefectDojo is not configured - upload skipped")
        return 0
    vendor, _, app = ENV.get("CICD_APP", "unknown/unknown").partition("/")
    bundle = ca_bundle()
    ctx = None
    if bundle and url.startswith("https"):
        import ssl  # noqa: PLC0415
        ctx = ssl.create_default_context(cafile=bundle)
    for name, scan_type in DOJO_SCAN_TYPES.items():
        path = os.path.join(a.out, name)
        if not os.path.isfile(path):
            continue
        with open(path, "rb") as fh:
            data = fh.read()
        body, ctype = multipart({
            "scan_type": scan_type, "product_type_name": "CI/CD Portal", "product_name": vendor,
            "engagement_name": f"{app} {ENV.get('CICD_ENV', 'dev')}", "test_title": name.rsplit(".", 1)[0],
            "auto_create_context": "true", "close_old_findings": "true", "deduplication_on_engagement": "true",
            "version": ENV.get("CICD_REF", ""), "commit_hash": ENV.get("CICD_COMMIT", ""),
            "build_id": ENV.get("CICD_BUILD_URL", ""), "minimum_severity": "Info", "active": "true",
            "verified": "false"}, {"file": (name, data)})
        req = urllib.request.Request(f"{url}/api/v2/reimport-scan/", data=body, method="POST",
                                     headers={"Content-Type": ctype, "Authorization": f"Token {token}"})
        try:
            with urllib.request.urlopen(req, timeout=120, context=ctx) as resp:
                log(f"DefectDojo {name}: HTTP {resp.status}")
        except (urllib.error.URLError, OSError) as e:
            log(f"WARN DefectDojo upload of {name} failed: {getattr(e, 'reason', e)}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="cicd-scan", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("source"); p.add_argument("--dir", default="."); p.add_argument("--out", default="security")
    p = sub.add_parser("image"); p.add_argument("--image", required=True); p.add_argument("--out", default="security")
    p = sub.add_parser("gate"); p.add_argument("--out", default="security")
    p = sub.add_parser("upload"); p.add_argument("--out", default="security")
    a = ap.parse_args(argv)
    if a.cmd == "image":
        ENV["CICD_IMAGE"] = a.image
    try:
        return {"source": cmd_source, "image": cmd_image, "gate": cmd_gate, "upload": cmd_upload}[a.cmd](a)
    except Exception as e:  # noqa: BLE001
        log(f"ERROR {type(e).__name__}: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
