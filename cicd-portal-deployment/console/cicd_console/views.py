"""Pages of the CI/CD console (screens follow ap-pipeline-ui: pipeline list, pipeline detail with
build/deploy stages, build log history, contributors; plus the portal's onboarding scripts)."""
import concurrent.futures
import os
import re

from flask import (Blueprint, abort, flash, g, jsonify, redirect, render_template, request, session,
                   url_for)

from . import auth, config, jobs, quality, services
from .kube import KubeError

bp = Blueprint("main", __name__)
auth_bp = Blueprint("auth", __name__)

NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$")
USERS_RE = re.compile(r"^[A-Za-z0-9._@-]+(,[A-Za-z0-9._@-]+)*$")
TAG_RE = re.compile(r"^v\d+\.\d+\.\d+$")
TYPES = ["java-gradle", "java-maven", "php", "node", "vue"]


# ---------------------------------------------------------------------- auth ---
@auth_bp.route("/login")
def login():
    return redirect(auth.login_url(request.args.get("next", "/")))


@auth_bp.route("/oauth/callback")
def callback():
    return redirect(auth.finish_login(request.args))


@auth_bp.route("/logout")
def logout():
    session.clear()
    return redirect(auth.logout_url())


# ----------------------------------------------------------------- helpers ---
def _vendor_or_404(name):
    if not NAME_RE.match(name):
        abort(404)
    auth.require_vendor(name)
    v = services.vendor(name)
    if v is None:
        abort(404, f"업체 {name}이(가) 등록되어 있지 않습니다.")
    return v


def _app_or_404(vendor_info, app):
    if not NAME_RE.match(app):
        abort(404)
    a = services.application(vendor_info["name"], app)
    if a is None:
        abort(404, f"애플리케이션 {vendor_info['name']}/{app}이(가) 없습니다.")
    return a


def _try(fn, *args, **kwargs):
    """(result, error message) - a broken backend should not break the whole page."""
    try:
        return fn(*args, **kwargs), None
    except (services.BackendError, KubeError) as e:
        return None, str(e)
    except SystemExit as e:   # cicd_api.py helpers exit on fatal errors
        return None, str(e)


def _unknown_source(vendor_info, app):
    """Redirect with a message when the vendor's source is not recorded (no scm|gitlab label)."""
    _, err = _try(services.require_source, vendor_info)
    if err:
        flash(err, "error")
        return redirect(url_for("main.app_page", vendor=vendor_info["name"], app=app))
    return None


def can_release(vendor_info):
    # scm: vendor groups may build the -release job in Jenkins; gitlab: v* tags are protected (Maintainer)
    return auth.is_admin() or vendor_info["source"] == "scm"


def _audit(action, target):
    from flask import current_app  # noqa: PLC0415
    current_app.logger.info("audit user=%s action=%s target=%s", g.user["username"], action, target)


# --------------------------------------------------------------- dashboard ---
@bp.route("/")
def dashboard():
    allowed = auth.user_vendors()
    vendors = [v for v in services.vendors() if allowed is None or v["name"] in allowed]
    names = {v["name"] for v in vendors}
    apps = [a for a in services.applications() if a["vendor"] in names]
    stats = {
        "vendors": len(vendors), "apps": len(apps),
        "dev_healthy": sum(1 for a in apps if a["envs"].get("dev", {}).get("health") == "Healthy"),
        "prod_outofsync": sum(1 for a in apps if a["envs"].get("prod", {}).get("sync") == "OutOfSync"),
        "degraded": sum(1 for a in apps for e in a["envs"].values() if e["health"] in ("Degraded", "Missing")),
    }
    by_vendor = {v["name"]: [a for a in apps if a["vendor"] == v["name"]] for v in vendors}
    security = {}
    if apps and quality.installed():
        # worst gate result of the newest develop / release builds per application
        for a, state, err in quality.app_states(vendors, apps):
            results = [] if err else [quality.gate_of(summary)["result"] for _, summary in state.values()]
            security[(a["vendor"], a["app"])] = max(results or ["none"], key=lambda r: quality.RESULT_RANK[r])
        stats["security_bad"] = sum(1 for r in security.values() if r in ("warn", "fail"))
    return render_template("dashboard.html", vendors=vendors, apps=apps, by_vendor=by_vendor, stats=stats,
                           no_access=allowed == [], security=security)


# ------------------------------------------------------------------ vendor ---
def _last_builds(vendor_info, apps):
    def one(app):
        found, err = _try(services.builds, vendor_info, app["app"], 3)
        return app["app"], (found or [None])[0], err
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        return {name: (b, err) for name, b, err in pool.map(one, apps)}


@bp.route("/vendors/<vendor>")
def vendor_page(vendor):
    v = _vendor_or_404(vendor)
    apps = services.applications(vendor)
    last = _last_builds(v, apps) if apps else {}
    members, members_err = _try(services.members, vendor)
    quotas = {ns: services.namespace_quota(ns) for ns in v["namespaces"]}
    return render_template("vendor.html", v=v, apps=apps, last=last, members=members or [],
                           members_err=members_err, quotas=quotas, links=services.links(v))


@bp.route("/vendors/<vendor>/members", methods=["POST"])
@auth.admin_required
def vendor_members(vendor):
    v = _vendor_or_404(vendor)
    username = request.form.get("username", "").strip()
    action = request.form.get("action")
    if not USERS_RE.match(username) or "," in username or action not in ("add", "remove"):
        flash("사용자 ID를 확인하세요.", "error")
    else:
        note, err = _try(services.change_member, v, username, action == "add")
        _audit(f"member-{action}", f"{vendor}/{username}")
        if err:
            flash(err, "error")
        else:
            flash(f"{username}: {'구성원에 추가' if action == 'add' else '구성원에서 제외'}했습니다.", "ok")
            if note:
                flash(note, "warn")
    return redirect(url_for("main.vendor_page", vendor=vendor) + "#members")


# --------------------------------------------------------------------- app ---
@bp.route("/vendors/<vendor>/apps/<app>")
def app_page(vendor, app):
    v = _vendor_or_404(vendor)
    a = _app_or_404(v, app)
    build_list, builds_err = _try(services.builds, v, app)
    tags, tags_err = (None, None)
    if can_release(v):
        tags, tags_err = _try(services.release_tags, v, app)
    running = any(e["running"] for e in a["envs"].values()) or \
        any(b["status"] in ("running", "pending") for b in build_list or [])
    security, prod_gate = None, {"checked": False, "ok": True}
    if build_list is not None and quality.installed():
        security, sec_err = _try(quality.latest, v, app, build_list)
        if sec_err:
            flash(f"보안 검사 결과 조회 실패: {sec_err}", "warn")
        else:
            prod_gate, _ = _try(quality.prod_gate, v, app, build_list)
            prod_gate = prod_gate or {"checked": False, "ok": True}
    return render_template("app.html", v=v, a=a, builds=build_list or [], builds_err=builds_err,
                           tags=tags or [], tags_err=tags_err, running=running,
                           can_release=can_release(v), links=services.links(v, app),
                           security=security, prod_gate=prod_gate,
                           security_installed=quality.installed())


@bp.route("/vendors/<vendor>/apps/<app>/build", methods=["POST"])
def app_build(vendor, app):
    v = _vendor_or_404(vendor)
    _app_or_404(v, app)
    stop = _unknown_source(v, app)
    if stop:
        return stop
    if v["source"] == "scm":
        _, err = _try(lambda: services.Jenkins().trigger(vendor, f"{app}-dev"))
    else:
        _, err = _try(lambda: services.GitLab().trigger(f"{vendor}/{app}", "develop"))
    _audit("build-dev", f"{vendor}/{app}")
    flash(err or "develop 빌드를 시작했습니다. 완료되면 dev 환경에 자동 배포됩니다.", "error" if err else "ok")
    return redirect(url_for("main.app_page", vendor=vendor, app=app))


@bp.route("/vendors/<vendor>/apps/<app>/release", methods=["POST"])
def app_release(vendor, app):
    v = _vendor_or_404(vendor)
    _app_or_404(v, app)
    stop = _unknown_source(v, app)
    if stop:
        return stop
    if not can_release(v):
        abort(403, "GitLab 업체의 릴리스 태그는 PM(GitLab Maintainer)이 GitLab에서 만들거나 운영 관리자가 실행합니다.")
    tag = request.form.get("tag", "").strip()
    if not TAG_RE.match(tag):
        flash("릴리스 태그는 vX.Y.Z 형식이어야 합니다.", "error")
        return redirect(url_for("main.app_page", vendor=vendor, app=app))
    if v["source"] == "scm":
        _, err = _try(lambda: services.Jenkins().trigger(vendor, f"{app}-release", {"RELEASE_TAG": tag}))
        msg = f"릴리스 빌드({tag})를 시작했습니다. 이미지가 만들어지면 prod를 Sync하세요."
    else:
        ref = request.form.get("ref", "main").strip() or "main"
        _, err = _try(lambda: services.GitLab().create_tag(f"{vendor}/{app}", tag, ref))
        msg = f"태그 {tag}를 {ref}에서 만들었습니다. 릴리스 파이프라인이 끝나면 prod를 Sync하세요."
    _audit("release", f"{vendor}/{app}:{tag}")
    flash(err or msg, "error" if err else "ok")
    return redirect(url_for("main.app_page", vendor=vendor, app=app))


@bp.route("/vendors/<vendor>/apps/<app>/stop", methods=["POST"])
def app_stop(vendor, app):
    v = _vendor_or_404(vendor)
    _app_or_404(v, app)
    stop = _unknown_source(v, app)
    if stop:
        return stop
    build_id = request.form.get("id", "")
    job = request.form.get("job", "")
    if not build_id.isdigit():
        abort(400)
    if v["source"] == "scm":
        if job not in (f"{app}-dev", f"{app}-release"):
            abort(400)
        _, err = _try(lambda: services.Jenkins().stop(vendor, job, build_id))
    else:
        _, err = _try(lambda: services.GitLab().cancel(f"{vendor}/{app}", build_id))
    _audit("stop", f"{vendor}/{app}#{build_id}")
    flash(err or "빌드 중지를 요청했습니다.", "error" if err else "ok")
    return redirect(url_for("main.app_page", vendor=vendor, app=app))


@bp.route("/vendors/<vendor>/apps/<app>/sync", methods=["POST"])
def app_sync(vendor, app):
    v = _vendor_or_404(vendor)
    a = _app_or_404(v, app)
    env = request.form.get("env")
    if env not in a["envs"]:
        abort(400)
    revision = request.form.get("revision", "").strip() or None
    if (env == "prod" or revision) and not auth.is_admin():
        abort(403, "prod Sync와 롤백은 운영 관리자(cicd-admins)만 할 수 있습니다.")
    if revision and not re.match(r"^[0-9a-f]{7,40}$", revision):
        abort(400)
    if revision and a["envs"][env]["auto"]:
        flash("자동 Sync 환경(dev)은 롤백해도 다시 최신으로 돌아갑니다. gitops 저장소에서 이미지 태그를 되돌리세요.", "error")
        return redirect(url_for("main.app_page", vendor=vendor, app=app))
    reason = ""
    if env == "prod" and not revision:
        # 보안 게이트: the newest release build must pass, or the operator records why it is deployed anyway
        gate, gate_err = _try(quality.prod_gate, v, app)
        if gate_err or (gate and not gate["ok"]):
            reason = request.form.get("override_reason", "").strip()
            if len(reason) < 5:
                flash("최근 릴리스 빌드가 보안 게이트를 통과하지 않았습니다"
                      + (f" ({gate_err})" if gate_err else "") + ". 배포하려면 사유를 5자 이상 입력하세요.", "error")
                return redirect(url_for("main.app_page", vendor=vendor, app=app))
            _audit("security-override", f"{a['envs'][env]['name']}: {reason}")
    _, err = _try(services.sync, a["envs"][env]["name"], g.user["username"], revision, reason)
    _audit("rollback" if revision else "sync", f"{a['envs'][env]['name']}@{revision or 'target'}")
    flash(err or (f"{env} 롤백(Sync {revision[:7]})을 시작했습니다." if revision else f"{env} Sync를 시작했습니다."),
          "error" if err else "ok")
    return redirect(url_for("main.app_page", vendor=vendor, app=app))


@bp.route("/vendors/<vendor>/apps/<app>/refresh", methods=["POST"])
def app_refresh(vendor, app):
    v = _vendor_or_404(vendor)
    a = _app_or_404(v, app)
    errors = [err for e in a["envs"].values() for _, err in [_try(services.refresh, e["name"])] if err]
    flash("; ".join(errors) or "Argo CD에 상태 새로 고침을 요청했습니다.", "error" if errors else "ok")
    return redirect(url_for("main.app_page", vendor=vendor, app=app))


# -------------------------------------------------------------- build logs ---
@bp.route("/vendors/<vendor>/apps/<app>/builds/<job>/<build_id>")
def build_page(vendor, app, job, build_id):
    v = _vendor_or_404(vendor)
    _app_or_404(v, app)
    stop = _unknown_source(v, app)
    if stop:
        return stop
    if not build_id.isdigit():
        abort(404)
    gl_jobs, err = [], None
    if v["source"] == "scm":
        if job not in (f"{app}-dev", f"{app}-release"):
            abort(404)
        url = f"https://{os.environ.get('JENKINS_HOST')}/job/{vendor}/job/{job}/{build_id}/"
    else:
        gl_jobs, err = _try(services.GitLab().jobs, f"{vendor}/{app}", build_id)
        url = f"https://{os.environ.get('GITLAB_HOST')}/{vendor}/{app}/-/pipelines/{build_id}"
    return render_template("build.html", v=v, app=app, job=job, build_id=build_id, gl_jobs=gl_jobs or [],
                           err=err, url=url)


@bp.route("/vendors/<vendor>/apps/<app>/builds/<job>/<build_id>/security")
def build_security(vendor, app, job, build_id):
    v = _vendor_or_404(vendor)
    _app_or_404(v, app)
    stop = _unknown_source(v, app)
    if stop:
        return stop
    if not build_id.isdigit() or (v["source"] == "scm" and job not in (f"{app}-dev", f"{app}-release")):
        abort(404)
    from .quality_views import build_report  # noqa: PLC0415
    summary, gate = build_report(v, app, job, build_id)
    return render_template("quality/report.html", v=v, app=app, job=job, build_id=build_id, s=summary, gate=gate)


@bp.route("/api/vendors/<vendor>/apps/<app>/builds/<job>/<build_id>/log")
def build_log(vendor, app, job, build_id):
    v = _vendor_or_404(vendor)
    if not NAME_RE.match(app) or not build_id.isdigit():
        abort(404)
    try:
        services.require_source(v)
        if v["source"] == "scm":
            if job not in (f"{app}-dev", f"{app}-release"):
                abort(404)
            text, nxt, more = services.Jenkins().log(vendor, job, build_id, request.args.get("start", 0, type=int))
            return jsonify(text=text, next=nxt, more=more, append=True)
        gl_job = request.args.get("job", type=int)
        gl = services.GitLab()
        job_list = gl.jobs(f"{vendor}/{app}", build_id)
        if gl_job is None and job_list:
            gl_job = next((j["id"] for j in job_list if j["status"] in ("running", "failed")), job_list[-1]["id"])
        text = gl.trace(f"{vendor}/{app}", gl_job) if gl_job else ""
        status = next((j["status"] for j in job_list if j["id"] == gl_job), "")
        return jsonify(text=_strip_ansi(text), more=status in ("running", "pending"), append=False, job=gl_job,
                       jobs=job_list)
    except (services.BackendError, KubeError) as e:
        return jsonify(error=str(e)), 502


ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|section_(start|end):\d+:[^\r\n]*\r?\x1b\[0K")


def _strip_ansi(text):
    return ANSI.sub("", text or "")


# ------------------------------------------------------- admin: scripts ---
def _start(title, script, args, env=None, secrets=()):
    job = jobs.start(title, script, args, g.user["username"], env=env, secrets=secrets)
    _audit(script, " ".join(args))
    return redirect(url_for("main.job_page", job_id=job.id))


@bp.route("/admin/vendors/new", methods=["GET", "POST"])
@auth.admin_required
def vendor_new():
    form = request.form if request.method == "POST" else request.args
    errors = []
    if request.method == "POST":
        vendor = form.get("vendor", "").strip()
        source = form.get("source", "")
        ns_mode = form.get("ns_mode", "split")
        users = form.get("users", "").replace(" ", "")
        pm_users = form.get("pm_users", "").replace(" ", "")
        if not NAME_RE.match(vendor) or vendor in ("cicd", "default"):
            errors.append("업체 ID는 영문 소문자·숫자·'-' (2~30자)이며 cicd, default는 쓸 수 없습니다.")
        if source not in config.sources():
            errors.append("소스를 선택하세요.")
        if ns_mode not in ("split", "single"):
            errors.append("네임스페이스 구성을 선택하세요.")
        for value in (users, pm_users):
            if value and not USERS_RE.match(value):
                errors.append("사용자 목록은 쉼표로 구분한 Keycloak 사용자 ID입니다.")
        if not errors:
            env = {"PM_USERS": pm_users}
            secrets_ = []
            if source == "scm":
                if form.get("scm_ci_password"):
                    env["SCM_CI_PASSWORD"] = form["scm_ci_password"]
                    secrets_.append(form["scm_ci_password"])
                if form.get("scm_ci_user", "").strip():
                    if not USERS_RE.match(form["scm_ci_user"].strip()):
                        errors.append("CI 계정 ID를 확인하세요.")
                    env["SCM_CI_USER"] = form["scm_ci_user"].strip()
        if not errors:
            args = ["--source", source, "--namespace", ns_mode, vendor] + ([users] if users else [])
            return _start(f"업체 등록: {vendor}", "onboard-vendor.sh", args, env, secrets_)
    return render_template("vendor_new.html", form=form, errors=errors, sources=config.sources(),
                           existing=services.vendor(form.get("vendor", "")) if form.get("vendor") else None)


@bp.route("/vendors/<vendor>/apps/new", methods=["GET", "POST"])
@auth.admin_required
def app_new(vendor):
    v = _vendor_or_404(vendor)
    form = request.form if request.method == "POST" else request.args
    errors = []
    if request.method == "POST":
        app = form.get("app", "").strip()
        app_type = form.get("type", "")
        health = form.get("health", "").strip()
        if not NAME_RE.match(app) or app == "gitops":
            errors.append("앱 ID는 영문 소문자·숫자·'-' (2~30자)이며 gitops는 쓸 수 없습니다.")
        if app_type not in TYPES:
            errors.append("언어/빌드 유형을 선택하세요.")
        if health and not re.match(r"^/[A-Za-z0-9._/-]*$", health):
            errors.append("헬스 체크 경로는 /로 시작해야 합니다.")
        env = {}
        if form.get("skip_starter"):
            env["SKIP_STARTER"] = "1"
        if form.get("replace_ci"):
            env["REPLACE_CI"] = "1"
        if form.get("db") in ("dedicated", "shared"):
            env["DB"] = form["db"]
        scm_repo = form.get("scm_repo", "").strip()
        if scm_repo:
            if v["source"] != "scm" or not re.match(r"^[A-Za-z0-9._-]+$", scm_repo):
                errors.append("기존 SCM 저장소 이름을 확인하세요.")
            env["SCM_REPO"] = scm_repo
        if not errors:
            args = [vendor, app, app_type] + ([health] if health else [])
            return _start(f"앱 추가: {vendor}/{app} ({app_type})", "add-app.sh", args, env)
    return render_template("app_new.html", v=v, form=form, errors=errors, types=TYPES)


@bp.route("/vendors/<vendor>/apps/<app>/db", methods=["GET", "POST"])
@auth.admin_required
def app_db(vendor, app):
    v = _vendor_or_404(vendor)
    a = _app_or_404(v, app)
    form = request.form if request.method == "POST" else request.args
    errors = []
    if request.method == "POST":
        env_arg = form.get("env", "dev")
        mode = form.get("mode", "dedicated")
        if env_arg not in ("dev", "prod", "all") or mode not in ("dedicated", "shared", "external"):
            errors.append("환경과 방식을 선택하세요.")
        env, secrets_ = {}, []
        if form.get("secret_update"):
            env["DB_SECRET_UPDATE"] = "1"
        if mode == "external":
            for key in ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD"):
                value = form.get(key.lower(), "").strip()
                if not value:
                    errors.append(f"외부 DB는 {key} 값이 필요합니다.")
                env[key] = value
            if form.get("db_port", "").strip():
                if not form["db_port"].strip().isdigit():
                    errors.append("DB 포트는 숫자입니다.")
                env["DB_PORT"] = form["db_port"].strip()
            secrets_.append(env.get("DB_PASSWORD", ""))
        if not errors:
            return _start(f"DB 연결: {vendor}/{app} {env_arg} ({mode})", "add-db.sh",
                          [vendor, app, env_arg, mode], env, secrets_)
    return render_template("app_db.html", v=v, a=a, form=form, errors=errors)


@bp.route("/admin/check", methods=["POST"])
@auth.admin_required
def run_check():
    return _start("시스템 점검", "check-cicd-portal.sh", [])


@bp.route("/admin/jobs")
@auth.admin_required
def jobs_page():
    return render_template("jobs.html", jobs=jobs.all_jobs())


@bp.route("/admin/jobs/<job_id>")
@auth.admin_required
def job_page(job_id):
    job = jobs.get(job_id) or abort(404)
    return render_template("job.html", job=job)


@bp.route("/api/jobs/<job_id>")
@auth.admin_required
def job_log(job_id):
    job = jobs.get(job_id) or abort(404)
    offset = request.args.get("offset", 0, type=int)
    return jsonify(lines=job.lines[offset:], offset=len(job.lines), status=job.status, rc=job.rc)
