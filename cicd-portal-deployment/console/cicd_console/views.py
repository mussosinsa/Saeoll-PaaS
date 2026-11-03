"""Pages of the CI/CD console (screens follow ap-pipeline-ui: pipeline list, pipeline detail with
build/deploy stages, build log history, contributors; plus the portal's onboarding scripts)."""
import concurrent.futures
import os
import re
import shutil
import tempfile
import threading

from flask import (Blueprint, abort, flash, g, jsonify, make_response, redirect, render_template, request,
                   session, url_for)

from . import auth, config, jobs, quality, services
from .kube import KubeError

bp = Blueprint("main", __name__)
auth_bp = Blueprint("auth", __name__)

NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$")
USERS_RE = re.compile(r"^[A-Za-z0-9._@-]+(,[A-Za-z0-9._@-]+)*$")
TAG_RE = re.compile(r"^v\d+\.\d+\.\d+$")
TYPES = ["java-gradle", "java-maven", "php", "node", "vue", "image"]
IMAGE_TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")


def _jobs(app):
    """Jenkins jobs of an application: -dev/-release (built from source) or -deploy (image apps)."""
    return (f"{app}-dev", f"{app}-release", f"{app}-deploy")


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
    # 업체 중지: vendor members can only look (operators keep every action, e.g. 업체 재개)
    if request.method == "POST" and v.get("suspended") and not auth.is_admin():
        abort(403, f"업체 {name}은(는) 중지되어 있습니다. 빌드·배포·등록은 운영 관리자가 업체를 재개한 뒤 할 수 있습니다.")
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
        "prod_outofsync": sum(1 for a in apps if a["envs"].get("prod", {}).get("sync") == "OutOfSync"
                              and not a["envs"]["prod"].get("stopped")),
        "degraded": sum(1 for a in apps for e in a["envs"].values()
                        if e["health"] in ("Degraded", "Missing") and not e.get("stopped")),
        "stopped": sum(1 for a in apps for e in a["envs"].values() if e.get("stopped")),
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
    if action == "reset" and USERS_RE.match(username) and "," not in username:
        password, err = _try(services.reset_password, vendor, username)
        _audit("password-reset", f"{vendor}/{username}")
        if err:
            flash(err, "error")
            return redirect(url_for("main.vendor_page", vendor=vendor) + "#members")
        resp = make_response(render_template(
            "credentials.html", title=f"{vendor} 구성원 임시 비밀번호", creds=[(username, "", "", password)],
            errors=[], back=url_for("main.vendor_page", vendor=vendor) + "#members"))
        resp.headers["Cache-Control"] = "no-store"
        return resp
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
    images, images_err = (None, None)
    if a["type"] == "image":
        images, images_err = _try(services.Harbor().artifacts, vendor, app)
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
                           security=security, prod_gate=prod_gate, images=images or [], images_err=images_err,
                           security_installed=quality.installed())


@bp.route("/vendors/<vendor>/apps/<app>/build", methods=["POST"])
def app_build(vendor, app):
    v = _vendor_or_404(vendor)
    if _app_or_404(v, app)["type"] == "image":
        flash("이미지 배포 앱은 빌드하지 않습니다. '이미지 배포'에서 Harbor 태그를 고르세요.", "warn")
        return redirect(url_for("main.app_page", vendor=vendor, app=app))
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


@bp.route("/vendors/<vendor>/apps/<app>/image-deploy", methods=["POST"])
def app_image_deploy(vendor, app):
    """Image apps: deploy a Harbor tag to dev, or promote a vX.Y.Z already deployed to dev to prod
    (the job checks the digest; prod then needs the operator's prod Sync like every application)."""
    v = _vendor_or_404(vendor)
    a = _app_or_404(v, app)
    if a["type"] != "image":
        abort(400)
    tag, target = request.form.get("tag", "").strip(), request.form.get("target", "dev")
    if target not in ("dev", "prod") or not IMAGE_TAG_RE.match(tag):
        flash("이미지 태그를 확인하세요.", "error")
    elif target == "prod" and not TAG_RE.match(tag):
        flash("prod 승격은 vX.Y.Z 태그만 할 수 있습니다.", "error")
    else:
        digest, err = _try(services.deploy_image, v, app, tag, target)
        _audit(f"image-{target}", f"{vendor}/{app}:{tag}")
        if err:
            flash(f"배포 실행 실패: {err}", "error")
        elif target == "dev":
            flash(f"{tag} ({digest[:19]}) dev 배포를 시작했습니다. 보안 검사 후 dev에 자동 반영됩니다.", "ok")
        else:
            flash(f"{tag} prod 승격을 시작했습니다. dev에 배포됐던 이미지인지 확인한 뒤 prod 설정을 바꾸며, "
                  "운영 관리자가 prod Sync하면 운영에 반영됩니다.", "ok")
    return redirect(url_for("main.app_page", vendor=vendor, app=app))


@bp.route("/vendors/<vendor>/push-account", methods=["POST"])
@auth.admin_required
def vendor_push_account(vendor):
    v = _vendor_or_404(vendor)
    account, err = _try(services.push_account, v["name"])
    _audit("harbor-push-account", vendor)
    if err:
        flash(f"Harbor push 계정 발급 실패: {err}", "error")
        return redirect(url_for("main.vendor_page", vendor=vendor) + "#info")
    resp = make_response(render_template("push_account.html", v=v, name=account[0], secret=account[1],
                                         harbor_host=os.environ.get("HARBOR_HOST", "")))
    resp.headers["Cache-Control"] = "no-store"
    return resp


# ------------------------------------------------ 서비스 중지 / 삭제 (app, vendor) ---
REASON_MIN = 5


def _reason(form):
    return " ".join(form.get("reason", "").split())[:300]


@bp.route("/vendors/<vendor>/apps/<app>/state", methods=["POST"])
def app_state(vendor, app):
    """서비스 중지 / 재개 of dev (vendor members) or prod (operators): app-state.sh (gitops replicas 0)."""
    v = _vendor_or_404(vendor)
    a = _app_or_404(v, app)
    env_name, action, reason = request.form.get("env"), request.form.get("action"), _reason(request.form)
    if env_name not in a["envs"] or action not in ("stop", "start"):
        abort(400)
    if env_name == "prod" and not auth.is_admin():
        abort(403, "prod 서비스 중지·재개는 운영 관리자만 할 수 있습니다.")
    if action == "stop" and len(reason) < REASON_MIN:
        flash(f"중지 사유를 {REASON_MIN}자 이상 입력하세요.", "error")
        return redirect(url_for("main.app_page", vendor=vendor, app=app))
    env = {"ACTOR": g.user["username"], "REASON": reason,
           "CI": "disable" if request.form.get("ci_disable") and v["source"] == "scm" else "keep"}
    title = f"서비스 {'중지' if action == 'stop' else '재개'}: {vendor}/{app} {env_name}"
    return _start(title, "app-state.sh", [vendor, app, env_name, action], env)


def _app_plan(v, a):
    """What 앱 삭제 removes / may keep (the job log shows what was really found)."""
    prod = a["envs"].get("prod")
    prod_running = bool(prod and not prod.get("stopped") and prod.get("health") not in ("Missing", "Unknown"))
    repo = None if a["type"] == "image" else (
        f"SCM 저장소 {v['name']}-{a['app']}" if v["source"] == "scm" else f"GitLab 프로젝트 {v['name']}/{a['app']}")
    return {"envs": sorted(a["envs"]), "prod_running": prod_running, "repo": repo,
            "jobs": [f"{a['app']}-{j}" for j in ("dev", "release", "deploy")] if v["source"] == "scm" else []}


@bp.route("/vendors/<vendor>/apps/<app>/delete", methods=["GET", "POST"])
@auth.admin_required
def app_delete(vendor, app):
    v = _vendor_or_404(vendor)
    a = _app_or_404(v, app)
    plan = _app_plan(v, a)
    form = request.form if request.method == "POST" else {}
    errors = []
    if request.method == "POST":
        preview = request.form.get("preview") == "1"
        reason = _reason(form)
        if not preview:
            if form.get("confirm", "").strip() != app:
                errors.append(f"확인을 위해 앱 ID '{app}'를 정확히 입력하세요.")
            if len(reason) < REASON_MIN:
                errors.append(f"삭제 사유를 {REASON_MIN}자 이상 입력하세요.")
            if plan["prod_running"]:
                errors.append("prod가 실행 중입니다. 먼저 prod 서비스를 중지하세요.")
        if not errors:
            args = [] if preview else ["--yes"]
            for flag in ("delete-data", "delete-images", "delete-repo"):
                if form.get(flag.replace("-", "_")):
                    args.append(f"--{flag}")
            title = f"앱 삭제{' 미리보기' if preview else ''}: {vendor}/{app}"
            return _start(title, "remove-app.sh", args + [vendor, app],
                          {"ACTOR": g.user["username"], "REASON": reason,
                           "SCM_RESTART": "1" if form.get("scm_restart") else "0"})
    return render_template("app_delete.html", v=v, a=a, plan=plan, form=form, errors=errors)


@bp.route("/vendors/<vendor>/state", methods=["POST"])
@auth.admin_required
def vendor_state(vendor):
    _vendor_or_404(vendor)
    action, reason = request.form.get("action"), _reason(request.form)
    if action not in ("suspend", "resume"):
        abort(400)
    if action == "suspend" and len(reason) < REASON_MIN:
        flash(f"중지 사유를 {REASON_MIN}자 이상 입력하세요.", "error")
        return redirect(url_for("main.vendor_page", vendor=vendor) + "#info")
    title = f"업체 {'중지' if action == 'suspend' else '재개'}: {vendor}"
    return _start(title, "vendor-state.sh", [vendor, action], {"ACTOR": g.user["username"], "REASON": reason})


@bp.route("/vendors/<vendor>/delete", methods=["GET", "POST"])
@auth.admin_required
def vendor_delete(vendor):
    v = _vendor_or_404(vendor)
    apps = services.applications(vendor)
    running = [a["app"] for a in apps if _app_plan(v, a)["prod_running"]]
    form = request.form if request.method == "POST" else {}
    errors = []
    if request.method == "POST":
        preview = request.form.get("preview") == "1"
        reason = _reason(form)
        if not preview:
            if form.get("confirm", "").strip() != vendor:
                errors.append(f"확인을 위해 업체 ID '{vendor}'를 정확히 입력하세요.")
            if len(reason) < REASON_MIN:
                errors.append(f"삭제 사유를 {REASON_MIN}자 이상 입력하세요.")
            if apps and not form.get("with_apps"):
                errors.append("앱이 남아 있습니다. 앱을 먼저 삭제하거나 '모든 앱 함께 삭제'를 선택하세요.")
            if running:
                errors.append(f"prod가 실행 중인 앱이 있습니다({', '.join(running)}). 먼저 업체를 중지하세요.")
        args, env, opt_errors = _vendor_delete_options(form)
        errors += opt_errors
        if not errors:
            args = ([] if preview else ["--yes"]) + args
            title = f"업체 삭제{' 미리보기' if preview else ''}: {vendor}"
            return _start(title, "remove-vendor.sh", args + [vendor], dict(env, REASON=reason))
    return render_template("vendor_delete.html", v=v, apps=apps, running=running, form=form, errors=errors)


def _vendor_delete_options(form):
    """remove-vendor.sh options of the 업체 삭제 / 남은 업체 정리 forms: (args, env, errors)."""
    args, errors = [], []
    for flag in ("with-apps", "delete-data", "delete-images", "delete-repos", "delete-users"):
        if form.get(flag.replace("-", "_")):
            args.append(f"--{flag}")
    users = form.get("users", "").replace(" ", "")
    if users:
        if not USERS_RE.match(users):
            errors.append("추가로 삭제할 계정은 쉼표로 구분한 ID입니다.")
        elif "--delete-users" not in args:
            errors.append("추가 계정을 지우려면 '계정 삭제'를 선택하세요.")
        else:
            args += ["--users", users]
    env = {"ACTOR": g.user["username"], "SCM_RESTART": "1" if form.get("scm_restart") else "0"}
    return args, env, errors


@bp.route("/admin/vendors/cleanup", methods=["GET", "POST"])
@auth.admin_required
def vendor_cleanup():
    """남은 업체 정리: an interrupted 업체 삭제 left namespaces, repositories or accounts behind (no Argo CD project)."""
    form = request.form if request.method == "POST" else request.args
    errors = []
    if request.method == "POST":
        vendor = form.get("vendor", "").strip()
        preview = form.get("preview") == "1"
        reason = _reason(form)
        if not NAME_RE.match(vendor):
            errors.append("업체 ID를 확인하세요.")
        elif services.vendor(vendor) is not None:
            errors.append(f"업체 {vendor}은(는) 아직 등록되어 있습니다. 업체 화면의 업체 삭제를 사용하세요.")
        if not preview:
            if form.get("confirm", "").strip() != vendor:
                errors.append("확인을 위해 업체 ID를 한 번 더 정확히 입력하세요.")
            if len(reason) < REASON_MIN:
                errors.append(f"정리 사유를 {REASON_MIN}자 이상 입력하세요.")
        args, env, opt_errors = _vendor_delete_options(form)
        errors += opt_errors
        if not errors:
            args = ([] if preview else ["--yes"]) + args
            title = f"남은 업체 정리{' 미리보기' if preview else ''}: {vendor}"
            return _start(title, "remove-vendor.sh", args + [vendor], dict(env, REASON=reason))
    return render_template("vendor_cleanup.html", form=form, errors=errors)


# ------------------------------------------------- 컨테이너 이미지 등록 (upload) ---
_upload_lock = threading.Lock()     # one upload at a time (disk of the console Pod)
UPLOAD_CHUNK = 1024 * 1024


def _image_apps(vendor_name):
    return sorted(a["app"] for a in services.applications(vendor_name) if a.get("type") == "image")


@bp.route("/vendors/<vendor>/images/new")
def image_upload_page(vendor):
    v = _vendor_or_404(vendor)
    apps, err = _try(_image_apps, vendor)
    return render_template("image_upload.html", v=v, apps=apps or [], apps_err=err,
                           preset=request.args.get("app", ""), max_mb=config.upload_max_bytes() // (1024 * 1024))


def _upload_error(message, status=400):
    return jsonify(error=message), status


@bp.route("/vendors/<vendor>/images/upload", methods=["POST"])
def image_upload(vendor):
    """Receive an image file (raw request body, streamed to the upload directory) and run upload-image.sh:
    Harbor <vendor>/<app>:<tag> -> (dev deployment). Vendor members: existing image apps; new apps: admins."""
    v = _vendor_or_404(vendor)
    form = request.args
    app, tag, new = form.get("app", "").strip(), form.get("tag", "").strip(), form.get("new") == "1"
    errors, env = [], {"DEPLOY_DEV": "1" if form.get("deploy", "1") == "1" else "0",
                       "UPLOAD_USER": g.user["username"]}
    if v["source"] != "scm":
        errors.append("이미지 등록은 K-PaaS SCM + Jenkins 업체에서만 쓸 수 있습니다.")
    if not NAME_RE.match(app) or app == "gitops":
        errors.append("앱 ID는 영문 소문자·숫자·'-' (2~30자)이며 gitops는 쓸 수 없습니다.")
    if not IMAGE_TAG_RE.match(tag):
        errors.append("태그는 영문·숫자·'.'·'_'·'-' (128자 이내)입니다. 운영용은 v1.2.0 형식.")
    if errors:
        return _upload_error(" ".join(errors))
    existing, err = _try(services.application, vendor, app)
    if err:
        return _upload_error(f"앱 조회 실패: {err}", 502)
    if new:
        if not auth.is_admin():
            return _upload_error("새 앱 등록은 운영 관리자만 할 수 있습니다. 운영 관리자에게 앱 추가를 요청하세요.", 403)
        if existing:
            return _upload_error(f"앱 {app}이(가) 이미 있습니다. 기존 앱으로 선택하세요.")
        health, opts, errors = _runtime_options(form)
        if errors:
            return _upload_error(" ".join(errors))
        env.update(opts, NEW_APP="1", APP_HEALTH=health)
    elif not existing or existing.get("type") != "image":
        return _upload_error(f"{app}은(는) 이미지 배포 앱이 아닙니다 (유형 image인 앱만 이미지를 등록할 수 있습니다).")

    length, limit = request.content_length, config.upload_max_bytes()
    if not length:
        return _upload_error("업로드할 이미지 파일이 없습니다.", 411)
    if length > limit:
        return _upload_error(f"파일이 너무 큽니다 (최대 {limit // (1024 * 1024)}MiB). "
                             "큰 이미지는 Harbor push 계정으로 podman push 하세요.", 413)
    directory = config.upload_dir()
    os.makedirs(directory, mode=0o700, exist_ok=True)
    if not _upload_lock.acquire(blocking=False):
        return _upload_error("다른 이미지 업로드가 진행 중입니다. 잠시 뒤 다시 시도하세요.", 409)
    # one image in the upload directory at a time (uploaded, waiting or being pushed by upload-image.sh):
    # the emptyDir has a sizeLimit, exceeding it would evict the console Pod
    if os.listdir(directory) or shutil.disk_usage(directory).free < length * 3:
        _upload_lock.release()
        return _upload_error("다른 이미지 등록이 진행 중이거나 업로드 공간이 부족합니다. "
                             "작업이 끝난 뒤 다시 시도하세요.", 409)
    path = None
    try:
        fd, path = tempfile.mkstemp(prefix=f"{vendor}-{app}-", suffix=".image", dir=directory)
        received = 0
        with os.fdopen(fd, "wb") as fh:
            while True:
                chunk = request.stream.read(UPLOAD_CHUNK)
                if not chunk:
                    break
                received += len(chunk)
                if received > length:
                    raise ValueError("more data than Content-Length")
                fh.write(chunk)
        if received != length:
            raise ValueError(f"incomplete upload ({received}/{length} bytes)")
    except Exception as e:  # noqa: BLE001 - client gone, disk full, ...: never leave the file behind
        if path and os.path.exists(path):
            os.remove(path)
        from flask import current_app  # noqa: PLC0415
        current_app.logger.warning("image upload %s/%s failed: %s", vendor, app, e)
        return _upload_error(f"업로드가 완료되지 않았습니다: {e}", 400)
    finally:
        _upload_lock.release()
    env["UPLOAD_MAX_BYTES"] = str(limit * 2)     # decompressed .tar.gz
    title = f"이미지 등록: {vendor}/{app}:{tag}" + (" (새 앱)" if new else "")
    job = jobs.start(title, "upload-image.sh", [vendor, app, tag, path], g.user["username"], env=env)
    _audit("image-upload", f"{vendor}/{app}:{tag} {received} bytes")
    return jsonify(job=url_for("main.job_page", job_id=job.id))


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
        if job not in _jobs(app):
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
        if job not in _jobs(app):
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
    if not build_id.isdigit() or (v["source"] == "scm" and job not in _jobs(app)):
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
            if job not in _jobs(app):
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
        new_users, new_errors = _parse_new_users(form.get("new_users", ""), users, pm_users)
        errors += new_errors
        if not errors and new_users:
            taken, err = _try(services.existing_accounts, [u[0] for u in new_users], [u[2] for u in new_users])
            if err:
                errors.append(f"Keycloak 확인 실패: {err}")
            else:
                taken_users, taken_emails = taken
                if taken_users:
                    errors.append(f"Keycloak에 이미 있는 ID입니다: {', '.join(taken_users)}. "
                                  "기존 사용자는 '개발자' 칸에 넣거나 다른 ID를 쓰세요.")
                if taken_emails:
                    errors.append(f"다른 계정이 이미 쓰는 이메일입니다: {', '.join(taken_emails)}")
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
            created = []
            for username, name, email in new_users:
                password, err = _try(services.create_user, username, name, email)
                if err:
                    errors.append(f"{username} 생성 실패: {err}"
                                  + (f" (이미 생성됨: {', '.join(c[0] for c in created)})" if created else ""))
                    break
                created.append((username, name, email, password))
                _audit("user-create", f"{vendor}/{username}")
            if created and errors:   # show the passwords of the accounts that exist now
                return render_template("credentials.html", title=f"업체 등록: {vendor} — 일부 계정만 생성됨",
                                       creds=created, errors=errors, back=url_for("main.vendor_new"))
        if not errors:
            all_users = ",".join(x for x in [users] + [c[0] for c in created] if x)
            args = ["--source", source, "--namespace", ns_mode, vendor] + ([all_users] if all_users else [])
            job = jobs.start(f"업체 등록: {vendor}", "onboard-vendor.sh", args, g.user["username"], env=env,
                             secrets=secrets_)
            job.credentials = created or None
            _audit("onboard-vendor.sh", " ".join(args))
            return redirect(url_for("main.job_page", job_id=job.id))
    return render_template("vendor_new.html", form=form, errors=errors, sources=config.sources(),
                           existing=services.vendor(form.get("vendor", "")) if form.get("vendor") else None)


def _parse_new_users(text, users, pm_users):
    """'ID, 이름, 이메일' per line -> [(id, name, email)], errors."""
    result, errors, seen = [], [], set()
    listed = {u for u in (users + "," + pm_users).split(",") if u}
    for no, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) != 3 or not all(parts):
            errors.append(f"신규 계정 {no}번째 줄: 'ID, 이름, 이메일' 형식으로 입력하세요.")
            continue
        username, name, email = parts[0].lower(), parts[1], parts[2]
        if not services.NEW_USER_RE.match(username):
            errors.append(f"신규 계정 {username}: ID는 영문 소문자·숫자·'.'·'_'·'-' (2~63자)입니다.")
        elif not services.EMAIL_RE.match(email) or len(name) > 60:
            errors.append(f"신규 계정 {username}: 이름(60자 이내)과 이메일을 확인하세요.")
        elif username in seen or username in listed:
            errors.append(f"신규 계정 {username}: 목록에 두 번 들어 있습니다(개발자·PM 칸 포함).")
        else:
            seen.add(username)
            result.append((username, name, email))
    if len(result) > 30:
        errors.append("신규 계정은 한 번에 30명까지 만들 수 있습니다.")
    return result, errors


def _runtime_options(form):
    """Health check, container port and memory limit of 앱 추가 / 이미지 등록: (health, env, errors)."""
    errors, env = [], {}
    health = form.get("health", "").strip()
    if health and health not in ("tcp", "none") and not re.match(r"^/[A-Za-z0-9._/~-]*$", health):
        errors.append("헬스 체크는 /로 시작하는 경로, tcp 또는 none입니다.")
    port, memory = form.get("port", "").strip(), form.get("memory", "").strip()
    if port:
        if not port.isdigit() or not 1 <= int(port) <= 65535:
            errors.append("컨테이너 포트는 1~65535 숫자입니다.")
        env["APP_PORT"] = port
    if memory:
        if not re.match(r"^[0-9]+(Mi|Gi)$", memory):
            errors.append("메모리 상한은 512Mi, 1Gi 형식입니다.")
        env["APP_MEMORY_LIMIT"] = memory
    return health, env, errors


@bp.route("/vendors/<vendor>/apps/new", methods=["GET", "POST"])
@auth.admin_required
def app_new(vendor):
    v = _vendor_or_404(vendor)
    form = request.form if request.method == "POST" else request.args
    errors = []
    if request.method == "POST":
        app = form.get("app", "").strip()
        app_type = form.get("type", "")
        if not NAME_RE.match(app) or app == "gitops":
            errors.append("앱 ID는 영문 소문자·숫자·'-' (2~30자)이며 gitops는 쓸 수 없습니다.")
        if app_type not in TYPES:
            errors.append("언어/빌드 유형을 선택하세요.")
        health, env, opt_errors = _runtime_options(form)
        errors += opt_errors
        if app_type == "image" and v["source"] != "scm":
            errors.append("이미지 배포 앱은 K-PaaS SCM + Jenkins 업체에서만 쓸 수 있습니다.")
        if form.get("skip_starter"):
            env["SKIP_STARTER"] = "1"
        if form.get("replace_ci"):
            env["REPLACE_CI"] = "1"
        if form.get("db") in ("dedicated", "shared"):
            env["DB"] = form["db"]
        if v["source"] == "scm" and form.get("scm_create") and app_type != "image":
            env["SCM_CREATE_REPO"] = "1"
            writers = form.get("scm_writers", "").replace(" ", "")
            if writers and not USERS_RE.match(writers):
                errors.append("쓰기 권한 사용자는 쉼표로 구분한 ID입니다.")
            env["SCM_WRITERS"] = writers
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


def _job_or_404(job_id):
    """Script jobs are visible to operators and to the user who started them (e.g. 컨테이너 이미지 등록)."""
    job = jobs.get(job_id) or abort(404)
    if not auth.is_admin() and job.user != g.user["username"]:
        abort(403)
    return job


@bp.route("/admin/jobs/<job_id>")
def job_page(job_id):
    job = _job_or_404(job_id)
    # temporary passwords of accounts created with the job: shown once, to the operator who started it
    creds = None
    if getattr(job, "credentials", None) and job.user == g.user["username"]:
        creds, job.credentials = job.credentials, None
    resp = make_response(render_template("job.html", job=job, creds=creds))
    if creds:
        resp.headers["Cache-Control"] = "no-store"
    return resp


@bp.route("/api/jobs/<job_id>")
def job_log(job_id):
    job = _job_or_404(job_id)
    offset = request.args.get("offset", 0, type=int)
    return jsonify(lines=job.lines[offset:], offset=len(job.lines), status=job.status, rc=job.rc)
