"""품질 관리: security scan results, policy, rules and exceptions (deploy-cicd-portal.sh security).

- Results: security/summary.json archived by the pipelines (Jenkins build artifact, GitLab job 'security').
- Policy (gates, profiles, application profiles, exceptions): ConfigMap cicd-security-policy, key policy.json,
  in every CI namespace (cicd-jenkins for scm, cicd-runner for gitlab). The first one is the source of truth;
  saves use its resourceVersion so two operators cannot overwrite each other.
- Rules: ConfigMap cicd-security-rules (Semgrep rule sets, gitleaks.toml, pii.json, settings.json), read only:
  the rules are maintained in the repository (security/rules) and installed by deploy-cicd-portal.sh security.
"""
import concurrent.futures
import copy
import datetime
import json
import os
import threading
import time
import tomllib

import yaml

from . import config, services
from .kube import KubeError, get_json, kubectl

POLICY_CM = "cicd-security-policy"
RULES_CM = "cicd-security-rules"
TOOLS = {
    "semgrep": ("Semgrep", "코드 취약점 (SQL 주입, 명령 주입, XSS 등)"),
    "gitleaks": ("Gitleaks", "비밀정보 (API 키, 비밀번호, 토큰)"),
    "trivy-fs": ("Trivy 의존성", "라이브러리 취약점 (composer.lock, package-lock.json, pom.xml 등)"),
    "pii": ("개인정보", "주민등록번호·카드번호 등 한국 개인정보 패턴"),
    "presidio": ("Presidio", "문맥 기반 개인정보 탐지 (Presidio 설치 시)"),
    "trivy-image": ("Trivy 이미지", "컨테이너 이미지 OS 패키지·라이브러리 취약점, 이미지 안의 비밀정보"),
}
SEMGREP_SETS = {"common": "공통", "php": "PHP", "java": "Java / Spring", "javascript": "JavaScript / TypeScript"}
GATE_KEYS = [("critical", "Critical"), ("high", "High"), ("medium", "Medium"), ("secret", "비밀정보"), ("pii", "개인정보")]
ENVS = [("dev", "dev (develop 빌드)"), ("prod", "prod (릴리스 빌드)"), ("branch", "기타 브랜치 / MR (GitLab)")]
RESULT_RANK = {"fail": 3, "warn": 2, "none": 1, "pass": 0}


class ConflictError(services.BackendError):
    pass


def namespaces():
    result = []
    if "scm" in config.sources():
        result.append(os.environ.get("JENKINS_NAMESPACE", "cicd-jenkins"))
    if "gitlab" in config.sources():
        result.append(os.environ.get("RUNNER_NAMESPACE", "cicd-runner"))
    return result


_installed = {"at": 0.0, "value": False}


def installed():
    """Security scan set up (policy ConfigMap present); cached for 30 seconds."""
    if _installed["at"] > time.time() - 30:
        return _installed["value"]
    value = False
    for ns in namespaces():
        try:
            if get_json("-n", ns, "configmap", POLICY_CM) is not None:
                value = True
                break
        except KubeError:
            continue
    _installed.update(at=time.time(), value=value)
    return value


# ------------------------------------------------------------------- policy ---
def load_policy():
    """(policy, resourceVersion, namespace) of the first CI namespace with the policy; (None, '', '') if none."""
    for ns in namespaces():
        cm = get_json("-n", ns, "configmap", POLICY_CM)
        if cm is None:
            continue
        try:
            pol = json.loads((cm.get("data") or {}).get("policy.json") or "{}")
        except ValueError as e:
            raise services.BackendError(f"{ns}/{POLICY_CM}의 policy.json이 올바른 JSON이 아닙니다: {e}") from None
        pol.setdefault("gates", {})
        pol.setdefault("profiles", {})
        pol.setdefault("apps", {})
        pol.setdefault("exceptions", [])
        return pol, cm["metadata"].get("resourceVersion", ""), ns
    return None, "", ""


def save_policy(pol, resource_version, user, note):
    """Write the policy to the first namespace (optimistic lock), then copy it to the other CI namespaces."""
    text = json.dumps(pol, ensure_ascii=False, indent=1)
    nss = namespaces()
    if not nss:
        raise services.BackendError("CI 네임스페이스가 없습니다 (CICD_SOURCES)")
    annotations = {"cicd.k-paas.org/updated-by": user, "cicd.k-paas.org/updated-at": now_iso(),
                   "cicd.k-paas.org/change": note[:200]}
    for i, ns in enumerate(nss):
        obj = {"apiVersion": "v1", "kind": "ConfigMap",
               "metadata": {"name": POLICY_CM, "namespace": ns, "annotations": annotations,
                            "labels": {"app.kubernetes.io/part-of": "cicd-portal"}},
               "data": {"policy.json": text}}
        try:
            if i == 0:
                obj["metadata"]["resourceVersion"] = resource_version
                kubectl("replace", "-f", "-", stdin=json.dumps(obj))
            else:
                kubectl("apply", "-f", "-", stdin=json.dumps(obj))
        except KubeError as e:
            if i == 0 and ("conflict" in str(e).lower() or "modified" in str(e).lower()):
                raise ConflictError("다른 사용자가 먼저 정책을 수정했습니다. 화면을 새로 고친 뒤 다시 저장하세요.") from None
            raise services.BackendError(f"{ns}/{POLICY_CM} 저장 실패: {e}") from None


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def policy_info(ns):
    """Who changed the policy last (annotations)."""
    cm = get_json("-n", ns, "configmap", POLICY_CM) if ns else None
    ann = ((cm or {}).get("metadata") or {}).get("annotations") or {}
    return {"by": ann.get("cicd.k-paas.org/updated-by", ""), "at": services.parse_time(ann.get("cicd.k-paas.org/updated-at")),
            "change": ann.get("cicd.k-paas.org/change", "")}


def app_profile(pol, vendor_name, app, app_type):
    name = ((pol.get("apps") or {}).get(f"{vendor_name}/{app}") or {}).get("profile") or app_type
    return name if name in (pol.get("profiles") or {}) else "default"


# -------------------------------------------------------------------- rules ---
def load_rules():
    """Rules installed in the cluster: {'semgrep': [...], 'gitleaks': {...}, 'pii': [...], 'settings': {...}}."""
    data = {}
    for ns in namespaces():
        cm = get_json("-n", ns, "configmap", RULES_CM)
        if cm:
            data = cm.get("data") or {}
            break
    result = {"semgrep": [], "gitleaks": {"extend_default": False, "rules": []}, "pii": [], "settings": {}, "errors": []}
    for key in sorted(data):
        if key.startswith("semgrep-") and key.endswith(".yml"):
            rule_set = key[len("semgrep-"):-len(".yml")]
            try:
                for r in (yaml.safe_load(data[key]) or {}).get("rules") or []:
                    meta = r.get("metadata") or {}
                    result["semgrep"].append({
                        "set": rule_set, "id": r.get("id"), "languages": ", ".join(r.get("languages") or []),
                        "severity": str(meta.get("cicd-severity") or {"ERROR": "high", "WARNING": "medium"}.get(
                            r.get("severity"), "low")).lower(),
                        "message": (r.get("message") or "").strip(), "cwe": meta.get("cwe", ""),
                        "description": meta.get("description", "")})
            except yaml.YAMLError as e:
                result["errors"].append(f"{key}: {e}")
    if "gitleaks.toml" in data:
        try:
            g = tomllib.loads(data["gitleaks.toml"])
            result["gitleaks"] = {"extend_default": bool((g.get("extend") or {}).get("useDefault")),
                                  "rules": [{"id": r.get("id"), "description": r.get("description", ""),
                                             "regex": r.get("regex", "")} for r in g.get("rules") or []],
                                  "allow_paths": (g.get("allowlist") or {}).get("paths") or []}
        except tomllib.TOMLDecodeError as e:
            result["errors"].append(f"gitleaks.toml: {e}")
    for key, target in (("pii.json", "pii"), ("settings.json", "settings")):
        if key in data:
            try:
                result[target] = json.loads(data[key])
            except ValueError as e:
                result["errors"].append(f"{key}: {e}")
    return result


# ----------------------------------------------------------------- results ---
_cache = {}
_cache_lock = threading.Lock()


def _cached(key, loader, ttl):
    with _cache_lock:
        hit = _cache.get(key)
        if hit and (hit[0] is None or hit[0] > time.time()):
            return hit[1]
    value = loader()
    with _cache_lock:
        if len(_cache) > 1000:
            _cache.clear()
        _cache[key] = (None if value is not None else time.time() + ttl, value)   # results never change
    return value


def _jenkins_summary(vendor_name, job, number):
    j = services.Jenkins()
    try:
        data, _ = services.http("GET", f"{j.base}{j.path(vendor_name, job)}/{int(number)}/artifact/security/summary.json",
                                j.headers)
        return data if isinstance(data, dict) else None
    except services.BackendError as e:
        if "HTTP 404" in str(e):
            return None
        raise


def _gitlab_summary(project, pipeline_id):
    gl = services.GitLab()
    pid = gl.project_id(project)
    jobs = gl.get(f"/projects/{pid}/pipelines/{int(pipeline_id)}/jobs?per_page=100&include_retried=false") or []
    job = next((j for j in sorted(jobs, key=lambda j: -j["id"]) if j.get("name") == "security"), None)
    if not job:
        return None
    try:
        data, _ = services.http("GET", f"{gl.base}/projects/{pid}/jobs/{job['id']}/artifacts/security/summary.json",
                                gl.headers)
        return data if isinstance(data, dict) else None
    except services.BackendError as e:
        if "HTTP 404" in str(e):
            return None
        raise


def build_summary(vendor_info, app, build):
    """summary.json of one finished build (None: not scanned)."""
    if build is None or build.get("status") in ("running", "pending"):
        return None
    if vendor_info["source"] == "scm":
        key = ("jenkins", vendor_info["name"], build["job"], str(build["id"]))
        return _cached(key, lambda: _jenkins_summary(vendor_info["name"], build["job"], build["id"]), 120)
    key = ("gitlab", vendor_info["name"], app, str(build["id"]))
    return _cached(key, lambda: _gitlab_summary(f"{vendor_info['name']}/{app}", build["id"]), 120)


def gate_of(summary):
    if not summary:
        return {"result": "none", "mode": "", "counts": {}, "violations": []}
    g = summary.get("gate") or {}
    return {"result": g.get("result", "none"), "mode": g.get("mode", ""), "counts": summary.get("counts") or {},
            "violations": g.get("violations") or [], "generated": services.parse_time(summary.get("generated"))}


def latest(vendor_info, app, build_list=None):
    """{'dev': (build, summary), 'release': (build, summary)} of the newest finished develop / release builds."""
    if build_list is None:
        build_list = services.builds(vendor_info, app, 15)
    result = {}
    for scope in ("dev", "release"):
        build = next((b for b in build_list if b["pipeline"] == scope and b["status"] not in ("running", "pending")), None)
        result[scope] = (build, build_summary(vendor_info, app, build) if build else None)
    return result


def app_states(vendor_infos, apps, workers=8):
    """[(app entry, {'dev': (build, summary), 'release': ...} | None, error)] for many applications in parallel."""
    vmap = {v["name"]: v for v in vendor_infos}

    def one(a):
        try:
            return a, latest(vmap[a["vendor"]], a["app"]), None
        except (services.BackendError, KubeError, SystemExit) as e:
            return a, None, str(e)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(one, [a for a in apps if vmap.get(a["vendor"], {}).get("source") in ("scm", "gitlab")]))


def prod_gate(vendor_info, app, build_list=None):
    """Gate of the newest finished release build: what a prod sync would deploy. ok=False blocks the sync
    (operator override with a reason) when gates.prod.console_block is set."""
    if not installed():
        return {"checked": False, "ok": True}
    pol, _, _ = load_policy()
    block = bool(((pol or {}).get("gates") or {}).get("prod", {}).get("console_block", True))
    build, summary = latest(vendor_info, app, build_list)["release"]
    gate = gate_of(summary)
    return {"checked": True, "block": block, "ok": gate["result"] == "pass" or not block, "build": build,
            "gate": gate, "summary": summary}


def copy_policy(pol):
    return copy.deepcopy(pol)
