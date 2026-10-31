"""Read and operate the CI/CD portal: Argo CD (Kubernetes objects), Jenkins, GitLab, SCM-Manager, Keycloak.

Vendors are the Argo CD AppProjects created by onboard-vendor.sh, applications are the Argo CD
Applications <vendor>-<app>-<env> created by add-app.sh (labels cicd.k-paas.org/*), so the console
needs no database of its own.
"""
import base64
import datetime
import functools
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

from . import config
from .kube import KubeError, cicd_secret, get_json, kubectl

LABEL = "cicd.k-paas.org"


class BackendError(Exception):
    """A backend (Jenkins, GitLab, SCM, Keycloak, Kubernetes) failed or is not configured."""


@functools.lru_cache(maxsize=None)
def api():
    """cicd_api.py of the scripts (SSL context with the K-PaaS CA, Keycloak/GitLab helpers)."""
    if config.SCRIPT_DIR not in sys.path:
        sys.path.insert(0, config.SCRIPT_DIR)
    import cicd_api  # noqa: PLC0415 - needs CA_FILE in the environment first
    return cicd_api


def q(value):
    return urllib.parse.quote(str(value), safe="")


def http(method, url, headers=None, form=None, data=None, raw=False, timeout=30):
    """HTTP call; returns (body, response headers). JSON bodies are decoded unless raw."""
    headers = dict(headers or {})
    body = None
    if form is not None:
        body = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, context=api().CTX, timeout=timeout) as resp:
            text = resp.read().decode(errors="replace")
            if raw:
                return text, resp.headers
            return (json.loads(text) if text.strip() else None), resp.headers
    except urllib.error.HTTPError as e:
        raise BackendError(f"HTTP {e.code} {method} {url.split('?')[0]}: "
                           f"{e.read().decode(errors='replace')[:300]}") from None
    except (urllib.error.URLError, OSError) as e:
        raise BackendError(f"{url.split('?')[0]}: {getattr(e, 'reason', e)}") from None


def parse_time(value):
    """ISO 8601 (Argo CD, GitLab) or epoch milliseconds (Jenkins) -> aware datetime."""
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return datetime.datetime.fromtimestamp(value / 1000, datetime.timezone.utc)
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


# ------------------------------------------------------------------- Argo CD ---
def _ns():
    return os.environ["ARGOCD_NAMESPACE"]


def vendors():
    """Onboarded vendors (Argo CD AppProjects except 'default')."""
    data = get_json("-n", _ns(), "appprojects.argoproj.io") or {"items": []}
    result = []
    for p in data["items"]:
        meta = p["metadata"]
        if meta["name"] == "default":
            continue
        labels = meta.get("labels") or {}
        ns_mode = labels.get(f"{LABEL}/ns-mode", "split")
        name = meta["name"]
        result.append({
            "name": name,
            "source": labels.get(f"{LABEL}/source") or _source_from_repos(p),
            "ns_mode": ns_mode,
            "ci_user": (meta.get("annotations") or {}).get(f"{LABEL}/scm-ci-user") or "",
            "namespaces": [name] if ns_mode == "single" else [f"{name}-dev", f"{name}-prod"],
            "repos": (p.get("spec") or {}).get("sourceRepos") or [],
            "created": parse_time(meta.get("creationTimestamp")),
        })
    return sorted(result, key=lambda v: v["name"])


def _source_from_repos(project):
    repos = " ".join((project.get("spec") or {}).get("sourceRepos") or [])
    if os.environ.get("SCM_INTERNAL_GIT_URL") and os.environ["SCM_INTERNAL_GIT_URL"] in repos:
        return "scm"
    if os.environ.get("GITLAB_INTERNAL_URL") and os.environ["GITLAB_INTERNAL_URL"] in repos:
        return "gitlab"
    return ""


def vendor(name):
    return next((v for v in vendors() if v["name"] == name), None)


def env_summary(obj):
    """Status of one Argo CD Application (dev or prod)."""
    st = obj.get("status") or {}
    spec = obj.get("spec") or {}
    op = st.get("operationState") or {}
    history = []
    for h in reversed(st.get("history") or []):
        history.append({"id": h.get("id"), "revision": h.get("revision") or "",
                        "deployed": parse_time(h.get("deployedAt")),
                        "initiated_by": ((h.get("initiatedBy") or {}).get("username") or
                                         ("자동 Sync" if (h.get("initiatedBy") or {}).get("automated") else ""))})
    images = (st.get("summary") or {}).get("images") or []
    # the application image is the one in Harbor (a dedicated DB adds e.g. docker.io/library/mariadb:11.4)
    harbor = os.environ.get("HARBOR_HOST", "")
    app_images = [i for i in images if harbor and i.startswith(harbor + "/")] or images
    app_image = app_images[0] if app_images else ""
    return {
        "name": obj["metadata"]["name"],
        "namespace": (spec.get("destination") or {}).get("namespace", ""),
        "auto": bool((spec.get("syncPolicy") or {}).get("automated")),
        "sync": (st.get("sync") or {}).get("status") or "Unknown",
        "revision": (st.get("sync") or {}).get("revision") or "",
        "health": (st.get("health") or {}).get("status") or "Unknown",
        "health_message": (st.get("health") or {}).get("message") or "",
        "images": images,
        "tag": app_image.rsplit(":", 1)[-1] if ":" in app_image.rsplit("/", 1)[-1] else "",
        "urls": (st.get("summary") or {}).get("externalURLs") or [],
        "op_phase": op.get("phase") or "",
        "op_message": op.get("message") or "",
        "op_finished": parse_time(op.get("finishedAt")),
        "running": "operation" in obj or op.get("phase") == "Running",
        "history": history[:10],
        "resources": [{"kind": r.get("kind"), "name": r.get("name"), "status": r.get("status") or "",
                       "health": (r.get("health") or {}).get("status") or "",
                       "message": (r.get("health") or {}).get("message") or ""}
                      for r in st.get("resources") or []],
        "conditions": [c.get("message", "") for c in st.get("conditions") or []],
        "reconciled": parse_time(st.get("reconciledAt")),
    }


def applications(vendor_name=None):
    """Applications grouped by vendor/app: {vendor, app, type, envs: {dev: summary, prod: summary}}."""
    selector = f"{LABEL}/vendor={vendor_name}" if vendor_name else f"{LABEL}/vendor"
    data = get_json("-n", _ns(), "applications.argoproj.io", "-l", selector) or {"items": []}
    apps = {}
    for obj in data["items"]:
        labels = obj["metadata"].get("labels") or {}
        key = (labels.get(f"{LABEL}/vendor"), labels.get(f"{LABEL}/app"))
        if not all(key):
            continue
        entry = apps.setdefault(key, {"vendor": key[0], "app": key[1], "type": labels.get(f"{LABEL}/type", ""),
                                      "envs": {}})
        entry["envs"][labels.get(f"{LABEL}/env", "dev")] = env_summary(obj)
    return sorted(apps.values(), key=lambda a: (a["vendor"], a["app"]))


def application(vendor_name, app):
    return next((a for a in applications(vendor_name) if a["app"] == app), None)


def sync(app_name, user, revision=None):
    """Start an Argo CD sync by setting .operation on the Application (what 'argocd app sync' does).
    revision: a gitops commit of the application's history (rollback); default: the target revision."""
    obj = get_json("-n", _ns(), "applications.argoproj.io", app_name)
    if obj is None:
        raise BackendError(f"Argo CD application {app_name} not found")
    if "operation" in obj or ((obj.get("status") or {}).get("operationState") or {}).get("phase") == "Running":
        raise BackendError(f"{app_name}: 이미 Sync가 진행 중입니다. 완료 후 다시 시도하세요.")
    target = revision or (obj["spec"].get("source") or {}).get("targetRevision") or "HEAD"
    patch = {"operation": {
        "initiatedBy": {"username": f"{user} (cicd-console)"},
        "info": [{"name": "Reason", "value": "rollback" if revision else "sync"}],
        "sync": {"revision": target, "prune": True, "syncStrategy": {"hook": {}}},
    }}
    try:
        kubectl("-n", _ns(), "patch", "applications.argoproj.io", app_name, "--type", "merge",
                "--patch-file", "/dev/stdin", stdin=json.dumps(patch))
    except KubeError as e:
        raise BackendError(str(e)) from None


def refresh(app_name):
    try:
        kubectl("-n", _ns(), "annotate", "applications.argoproj.io", app_name, "--overwrite",
                "argocd.argoproj.io/refresh=normal")
    except KubeError as e:
        raise BackendError(str(e)) from None


# ------------------------------------------------------------------- builds ---
def _jenkins_status(build):
    if build.get("building"):
        return "running"
    return {"SUCCESS": "success", "FAILURE": "failed", "ABORTED": "canceled", "UNSTABLE": "unstable",
            "NOT_BUILT": "skipped"}.get(build.get("result") or "", "pending")


def _gitlab_status(status):
    return {"created": "pending", "waiting_for_resource": "pending", "preparing": "pending",
            "scheduled": "pending", "manual": "manual"}.get(status, status or "unknown")


class Jenkins:
    """Jenkins of scm vendors: jobs <vendor>/<app>-dev (develop) and <vendor>/<app>-release (RELEASE_TAG)."""
    TREE = ("builds[number,result,building,timestamp,duration,displayName,"
            "actions[parameters[name,value],causes[shortDescription,userId]]]{0,%d}")

    def __init__(self):
        user, token = cicd_secret("jenkins-user"), cicd_secret("jenkins-api-token")
        if not (user and token):
            raise BackendError("Jenkins API 토큰이 없습니다 (./deploy-cicd-portal.sh jenkins-token)")
        self.headers = {"Authorization": "Basic " + base64.b64encode(f"{user}:{token}".encode()).decode()}
        self.base = os.environ["JENKINS_URL"].rstrip("/")
        self.public = f"https://{os.environ.get('JENKINS_HOST', '')}"

    def path(self, folder, job):
        return f"/job/{q(folder)}/job/{q(job)}"

    def builds(self, folder, job, limit=15):
        try:
            data, _ = http("GET", f"{self.base}{self.path(folder, job)}/api/json?tree={q(self.TREE % limit)}",
                           self.headers)
        except BackendError as e:
            if "HTTP 404" in str(e):
                return []
            raise
        result = []
        for b in data.get("builds") or []:
            params, cause = {}, ""
            for a in b.get("actions") or []:
                for p in a.get("parameters") or []:
                    params[p.get("name")] = p.get("value")
                for c in a.get("causes") or []:
                    cause = cause or c.get("shortDescription", "")
            result.append({"id": str(b["number"]), "number": b["number"], "job": job,
                           "pipeline": "release" if job.endswith("-release") else "dev",
                           "status": _jenkins_status(b), "ref": params.get("RELEASE_TAG") or "develop",
                           "started": parse_time(b.get("timestamp")), "duration": (b.get("duration") or 0) / 1000,
                           "cause": cause,
                           "url": f"{self.public}{self.path(folder, job)}/{b['number']}/"})
        return result

    def trigger(self, folder, job, params=None):
        base = f"{self.base}{self.path(folder, job)}"
        try:
            http("POST", f"{base}/buildWithParameters", self.headers, form=params or {"RELEASE_TAG": ""}, raw=True)
        except BackendError as e:
            if params or "HTTP 400" not in str(e) and "HTTP 500" not in str(e):
                raise
            http("POST", f"{base}/build", self.headers, form={}, raw=True)   # job without parameters yet

    def stop(self, folder, job, number):
        http("POST", f"{self.base}{self.path(folder, job)}/{int(number)}/stop", self.headers, form={}, raw=True)

    def log(self, folder, job, number, start=0):
        """Console output from byte offset start: (text, next offset, more data)."""
        text, headers = http("GET", f"{self.base}{self.path(folder, job)}/{int(number)}/logText/progressiveText"
                                    f"?start={int(start)}", self.headers, raw=True)
        return text, int(headers.get("X-Text-Size") or start), headers.get("X-More-Data") == "true"


class GitLab:
    """GitLab of gitlab vendors: project <vendor>/<app> (develop -> dev, tag vX.Y.Z -> prod)."""

    def __init__(self):
        token = cicd_secret("automation-token")
        if not token:
            raise BackendError("GitLab automation 토큰이 없습니다 (./deploy-cicd-portal.sh bootstrap)")
        self.headers = {"PRIVATE-TOKEN": token}
        self.base = os.environ["GITLAB_URL"].rstrip("/") + "/api/v4"
        self.public = f"https://{os.environ.get('GITLAB_HOST', '')}"

    def get(self, path):
        return http("GET", self.base + path, self.headers)[0]

    def project_id(self, project):
        return self.get(f"/projects/{q(project)}")["id"]

    def builds(self, project, limit=15):
        try:
            pid = self.project_id(project)
        except BackendError as e:
            if "HTTP 404" in str(e):
                return []
            raise
        result = []
        for p in self.get(f"/projects/{pid}/pipelines?per_page={limit}") or []:
            ref = p.get("ref") or ""
            result.append({"id": str(p["id"]), "number": p.get("iid") or p["id"], "job": project,
                           "pipeline": "release" if ref.startswith("v") else ("dev" if ref == "develop" else "other"),
                           "status": _gitlab_status(p.get("status")), "ref": ref,
                           "started": parse_time(p.get("created_at")), "duration": None,
                           "cause": p.get("source", ""), "url": p.get("web_url") or ""})
        return result

    def jobs(self, project, pipeline_id):
        pid = self.project_id(project)
        jobs = self.get(f"/projects/{pid}/pipelines/{int(pipeline_id)}/jobs?per_page=100") or []
        return [{"id": j["id"], "name": j.get("name"), "stage": j.get("stage"),
                 "status": _gitlab_status(j.get("status")), "duration": j.get("duration"),
                 "url": j.get("web_url")} for j in sorted(jobs, key=lambda j: j["id"])]

    def trace(self, project, job_id):
        pid = self.project_id(project)
        return http("GET", f"{self.base}/projects/{pid}/jobs/{int(job_id)}/trace", self.headers, raw=True)[0]

    def trigger(self, project, ref):
        pid = self.project_id(project)
        http("POST", f"{self.base}/projects/{pid}/pipeline?ref={q(ref)}", self.headers)

    def cancel(self, project, pipeline_id):
        pid = self.project_id(project)
        http("POST", f"{self.base}/projects/{pid}/pipelines/{int(pipeline_id)}/cancel", self.headers)

    def tags(self, project):
        pid = self.project_id(project)
        return [t["name"] for t in self.get(f"/projects/{pid}/repository/tags?per_page=30&order_by=updated") or []]

    def create_tag(self, project, tag, ref="main"):
        pid = self.project_id(project)
        http("POST", f"{self.base}/projects/{pid}/repository/tags?tag_name={q(tag)}&ref={q(ref)}", self.headers)

    def sync_member(self, group, username, add):
        """Add (Developer) or remove a vendor group member; users appear in GitLab after their first sign-in."""
        users = self.get(f"/users?username={q(username)}") or []
        if not users:
            return False
        gid = self.get(f"/groups/{q(group)}")["id"]
        uid = users[0]["id"]
        try:
            if add:
                http("POST", f"{self.base}/groups/{gid}/members", self.headers,
                     data={"user_id": uid, "access_level": 30})
            else:
                http("DELETE", f"{self.base}/groups/{gid}/members/{uid}", self.headers, raw=True)
        except BackendError as e:
            if "HTTP 409" not in str(e) and "HTTP 404" not in str(e):
                raise
        return True


def scm_tags(repo):
    """Tags of a K-PaaS SCM (SCM-Manager 1.x) repository - the release job builds refs/tags/<tag>."""
    password = os.environ.get("SCM_ADMIN_PASSWORD", "")
    if not password:
        raise BackendError("SCM_ADMIN_PASSWORD가 설정되지 않아 태그를 조회할 수 없습니다")
    cred = base64.b64encode(f"{os.environ.get('SCM_ADMIN_USER', 'scmadmin')}:{password}".encode()).decode()
    headers = {"Authorization": "Basic " + cred}
    base = os.environ["SCM_URL"].rstrip("/") + "/api/rest"
    repos = http("GET", f"{base}/repositories.json", headers)[0] or []
    found = [r for r in repos if r.get("name") == repo]
    if not found:
        return []
    data = http("GET", f"{base}/repositories/{q(found[0]['id'])}/tags.json", headers)[0] or {}
    tags = data.get("tag") or []
    if isinstance(tags, dict):
        tags = [tags]
    return sorted((t.get("name") for t in tags if t.get("name")), reverse=True)


def require_source(vendor_info):
    """Vendors without a recorded source (projects made before the label, or not by onboard-vendor.sh)."""
    if vendor_info["source"] not in ("scm", "gitlab"):
        raise BackendError(f"업체 {vendor_info['name']}의 소스(scm|gitlab)를 알 수 없습니다. "
                           f"./onboard-vendor.sh --source <scm|gitlab> {vendor_info['name']} 를 다시 실행해 기록하세요.")


def builds(vendor_info, app, limit=15):
    """Recent builds of an application (scm: Jenkins jobs -dev and -release, gitlab: pipelines)."""
    require_source(vendor_info)
    if vendor_info["source"] == "scm":
        j = Jenkins()
        found = j.builds(vendor_info["name"], f"{app}-dev", limit) + j.builds(vendor_info["name"], f"{app}-release", limit)
    else:
        found = GitLab().builds(f"{vendor_info['name']}/{app}", limit)
    epoch = datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)
    return sorted(found, key=lambda b: b["started"] or epoch, reverse=True)[:limit]


def release_tags(vendor_info, app):
    require_source(vendor_info)
    if vendor_info["source"] == "scm":
        return scm_tags(f"{vendor_info['name']}-{app}")
    return GitLab().tags(f"{vendor_info['name']}/{app}")


def links(vendor_info, app=None):
    """Web UI links of the vendor (and application)."""
    env = os.environ
    v = vendor_info["name"]
    result = {"argocd": f"https://{env.get('ARGOCD_HOST')}/applications?labels={q(f'{LABEL}/vendor={v}')}",
              "harbor": f"{env.get('HARBOR_URL', '').rstrip('/')}/harbor/projects"}
    if vendor_info["source"] == "scm":
        result["jenkins"] = f"https://{env.get('JENKINS_HOST')}/job/{q(v)}/"
        result["scm"] = f"https://scm.{env.get('HOST_DOMAIN')}"
    elif vendor_info["source"] == "gitlab":
        result["gitlab"] = f"https://{env.get('GITLAB_HOST')}/{v}" + (f"/{app}" if app else "")
    if app:
        result["argocd"] = f"https://{env.get('ARGOCD_HOST')}/applications?labels={q(f'{LABEL}/app={app}')}"
        result["harbor"] = f"{env.get('HARBOR_URL', '').rstrip('/')}/harbor/projects"
    return result


# ------------------------------------------------------------------ Keycloak ---
def members(vendor_name):
    """Usernames in Keycloak group cicd-<vendor> (Argo CD / Jenkins / console access)."""
    kc = api().Keycloak()
    group = f"cicd-{vendor_name}"
    for g in kc.call("GET", f"/groups?search={q(group)}") or []:
        if g["name"] == group:
            return sorted((u["username"], u.get("email") or "", f"{u.get('firstName') or ''} {u.get('lastName') or ''}".strip())
                          for u in kc.call("GET", f"/groups/{g['id']}/members?max=500") or [])
    return []


def change_member(vendor_info, username, add):
    """Add/remove a developer: Keycloak group cicd-<vendor> (+ GitLab group <vendor> for gitlab vendors)."""
    kc = api().Keycloak()
    group = f"cicd-{vendor_info['name']}"
    users = [u for u in kc.call("GET", f"/users?username={q(username)}&exact=true") or []
             if u["username"] == username.lower()]
    if not users:
        raise BackendError(f"Keycloak 사용자 {username}을(를) 찾을 수 없습니다 (CP-Portal 사용자로 먼저 등록)")
    gid = kc.ensure_group(group)
    kc.call("PUT" if add else "DELETE", f"/users/{users[0]['id']}/groups/{gid}")
    note = ""
    if vendor_info["source"] == "gitlab":
        if not GitLab().sync_member(vendor_info["name"], username, add) and add:
            note = "GitLab에 아직 로그인한 적이 없어 GitLab 그룹에는 추가되지 않았습니다. 첫 로그인 후 다시 추가하세요."
    return note


def namespace_quota(namespace):
    """ResourceQuota usage of a vendor namespace (vendor-quota from onboard-vendor.sh)."""
    try:
        q_ = get_json("-n", namespace, "resourcequota", "vendor-quota")
    except KubeError:
        return None
    if not q_:
        return None
    st = q_.get("status") or {}
    return [{"name": k, "used": (st.get("used") or {}).get(k, "0"), "hard": v}
            for k, v in sorted((st.get("hard") or {}).items())]

