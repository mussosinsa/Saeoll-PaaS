"""품질 관리 menu (ap-pipeline-ui 품질 이슈 / 코딩 규칙 / 품질 프로파일 / 품질 게이트 -> security scan)."""
import datetime
import re
import uuid

from flask import Blueprint, abort, current_app, flash, g, redirect, render_template, request, url_for

from . import auth, quality, services
from .kube import KubeError

qbp = Blueprint("quality", __name__, url_prefix="/quality")
NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$")
APP_KEY_RE = re.compile(r"^[a-z0-9-]{1,30}/[a-z0-9-]{1,30}$")
RULE_RE = re.compile(r"^[A-Za-z0-9_.:*\-]{1,120}$")

SEV_ORDER = ["critical", "high", "medium", "low", "info"]


def _visible_vendors():
    allowed = auth.user_vendors()
    return [v for v in services.vendors() if allowed is None or v["name"] in allowed]


def _policy_or_none():
    try:
        return quality.load_policy()
    except (services.BackendError, KubeError) as e:
        flash(str(e), "error")
        return None, "", ""


@qbp.route("/issues")
def issues():
    if not quality.installed():
        return render_template("quality/not_installed.html")
    vendors = _visible_vendors()
    names = {v["name"] for v in vendors}
    f = {k: request.args.get(k, "") for k in ("vendor", "app", "severity", "category", "tool", "result")}
    scope = request.args.get("scope", "dev")
    if scope not in ("dev", "release"):
        scope = "dev"
    apps = [a for a in services.applications() if a["vendor"] in names
            and (not f["vendor"] or a["vendor"] == f["vendor"]) and (not f["app"] or a["app"] == f["app"])]
    rows, findings, errors = [], [], []
    for a, state, err in quality.app_states(vendors, apps):
        if err:
            errors.append(f"{a['vendor']}/{a['app']}: {err}")
            continue
        build, summary = state[scope]
        gate = quality.gate_of(summary)
        if f["result"] and gate["result"] != f["result"]:
            continue
        rows.append({"app": a, "build": build, "summary": summary, "gate": gate})
        for item in (summary or {}).get("findings") or []:
            if f["severity"] and item.get("severity") != f["severity"]:
                continue
            if f["category"] and item.get("category") != f["category"]:
                continue
            if f["tool"] and item.get("tool") != f["tool"]:
                continue
            findings.append(dict(item, vendor=a["vendor"], app_name=a["app"], build=build))
    findings.sort(key=lambda x: (SEV_ORDER.index(x["severity"]) if x["severity"] in SEV_ORDER else 9,
                                 x["vendor"], x["app_name"], x["file"], x["line"]))
    total = len(findings)
    return render_template("quality/issues.html", rows=rows, findings=findings[:1000], total=total, errors=errors,
                           f=f, scope=scope, vendors=vendors, apps=apps, tools=quality.TOOLS)


@qbp.route("/rules")
def rules():
    if not quality.installed():
        return render_template("quality/not_installed.html")
    try:
        data = quality.load_rules()
    except (services.BackendError, KubeError) as e:
        abort(502, str(e))
    return render_template("quality/rules.html", rules=data, sets=quality.SEMGREP_SETS, tools=quality.TOOLS)


@qbp.route("/profiles")
def profiles():
    if not quality.installed():
        return render_template("quality/not_installed.html")
    pol, rv, ns = _policy_or_none()
    vendors = _visible_vendors()
    names = {v["name"] for v in vendors}
    apps = [a for a in services.applications() if a["vendor"] in names]
    assigned = {f"{a['vendor']}/{a['app']}": quality.app_profile(pol or {}, a["vendor"], a["app"], a["type"]) for a in apps}
    return render_template("quality/profiles.html", pol=pol or {}, rv=rv, apps=apps, assigned=assigned,
                           tools=quality.TOOLS, sets=quality.SEMGREP_SETS, info=quality.policy_info(ns))


@qbp.route("/gates")
def gates():
    if not quality.installed():
        return render_template("quality/not_installed.html")
    pol, rv, ns = _policy_or_none()
    return render_template("quality/gates.html", pol=pol or {}, rv=rv, keys=quality.GATE_KEYS, envs=quality.ENVS,
                           info=quality.policy_info(ns))


def build_report(vendor_info, app, job, build_id):
    build = {"job": job, "id": build_id, "status": "success"}
    summary = quality.build_summary(vendor_info, app, build)
    return summary, quality.gate_of(summary)


def register(app):
    app.register_blueprint(qbp)

    @app.context_processor
    def quality_globals():
        return {"quality_tools": quality.TOOLS}

    return app



# ------------------------------------------------------------ editing (phase 3) ---
def _save(pol, rv, note):
    try:
        quality.save_policy(pol, rv, g.user["username"], note)
    except (services.BackendError, KubeError) as e:
        flash(str(e), "error")
        return False
    current_app.logger.info("audit user=%s action=security-policy change=%s", g.user["username"], note)
    flash(f"저장했습니다: {note}. 다음 빌드부터 적용됩니다.", "ok")
    return True


def _int_limit(value):
    value = (value or "").strip()
    if value in ("", "-1"):
        return -1
    if not value.isdigit():
        raise ValueError(value)
    return int(value)


@qbp.route("/gates", methods=["POST"])
@auth.admin_required
def gates_save():
    pol, rv, _ = quality.load_policy()
    if pol is None:
        abort(404)
    if request.form.get("rv") != rv:
        flash("다른 사용자가 먼저 정책을 수정했습니다. 화면을 새로 고친 뒤 다시 저장하세요.", "error")
        return redirect(url_for("quality.gates"))
    changes = []
    try:
        for env, _ in quality.ENVS:
            old = pol["gates"].get(env) or {}
            mode = request.form.get(f"{env}.mode", old.get("mode", "report"))
            if mode not in ("report", "enforce"):
                abort(400)
            gate = {"mode": mode, "fail_on_tool_error": bool(request.form.get(f"{env}.fail_on_tool_error")),
                    "max": {k: _int_limit(request.form.get(f"{env}.max.{k}")) for k, _ in quality.GATE_KEYS}}
            if env == "prod":
                gate["console_block"] = bool(request.form.get("prod.console_block"))
            if gate != {k: old.get(k) for k in gate}:
                changes.append(f"{env} {quality_label(mode)}")
            pol["gates"][env] = gate
    except ValueError as e:
        flash(f"허용 건수는 0 이상의 숫자 또는 -1(제한 없음)입니다: {e}", "error")
        return redirect(url_for("quality.gates"))
    if changes:
        _save(pol, rv, "보안 게이트 " + ", ".join(changes))
    else:
        flash("바뀐 내용이 없습니다.", "warn")
    return redirect(url_for("quality.gates"))


def quality_label(mode):
    return "차단" if mode == "enforce" else "경고"


@qbp.route("/profiles", methods=["POST"])
@auth.admin_required
def profiles_save():
    pol, rv, _ = quality.load_policy()
    if pol is None:
        abort(404)
    if request.form.get("rv") != rv:
        flash("다른 사용자가 먼저 정책을 수정했습니다. 화면을 새로 고친 뒤 다시 저장하세요.", "error")
        return redirect(url_for("quality.profiles"))
    name = request.form.get("name", "").strip()
    if not NAME_RE.match(name):
        flash("프로파일 이름은 영문 소문자·숫자·'-'입니다.", "error")
        return redirect(url_for("quality.profiles"))
    if request.form.get("action") == "delete":
        if name == "default":
            flash("default 프로파일은 지울 수 없습니다.", "error")
        elif any((a or {}).get("profile") == name for a in pol["apps"].values()):
            flash(f"{name}을(를) 쓰는 앱이 있어 지울 수 없습니다. 앱의 프로파일을 먼저 바꾸세요.", "error")
        else:
            pol["profiles"].pop(name, None)
            _save(pol, rv, f"프로파일 {name} 삭제")
        return redirect(url_for("quality.profiles"))
    tools = [t for t in quality.TOOLS if request.form.get(f"tool.{t}")]
    sets = [s for s in quality.SEMGREP_SETS if request.form.get(f"set.{s}")]
    if not tools:
        flash("도구를 하나 이상 선택하세요.", "error")
        return redirect(url_for("quality.profiles", edit=name))
    pol["profiles"][name] = {"description": request.form.get("description", "").strip()[:100],
                             "tools": tools, "semgrep_rules": sets or ["common"]}
    _save(pol, rv, f"프로파일 {name} 저장")
    return redirect(url_for("quality.profiles"))


@qbp.route("/profiles/assign", methods=["POST"])
@auth.admin_required
def assign_profile():
    pol, rv, _ = quality.load_policy()
    if pol is None:
        abort(404)
    if request.form.get("rv") != rv:
        flash("다른 사용자가 먼저 정책을 수정했습니다. 화면을 새로 고친 뒤 다시 저장하세요.", "error")
        return redirect(url_for("quality.profiles"))
    key, profile = request.form.get("app", ""), request.form.get("profile", "")
    if not APP_KEY_RE.match(key) or (profile and profile not in pol["profiles"]):
        abort(400)
    if profile:
        pol["apps"][key] = {"profile": profile}
    else:
        pol["apps"].pop(key, None)
    _save(pol, rv, f"{key} 프로파일 → {profile or '유형 기본값'}")
    return redirect(url_for("quality.profiles"))


# --------------------------------------------------------------- exceptions ---
@qbp.route("/exceptions")
def exceptions():
    if not quality.installed():
        return render_template("quality/not_installed.html")
    pol, rv, _ = _policy_or_none()
    items = []
    today = datetime.date.today().isoformat()
    for e in (pol or {}).get("exceptions") or []:
        vendor_name = (e.get("app") or "").split("/")[0]
        if not auth.is_admin() and not auth.can_view(vendor_name):
            continue
        e = dict(e, expired=bool(e.get("expires")) and e["expires"] < today)
        items.append(e)
    items.sort(key=lambda e: ({"requested": 0, "approved": 1}.get(e.get("status"), 2), e.get("requested_at", "")),
               reverse=False)
    return render_template("quality/exceptions.html", items=items, rv=rv, form=request.args,
                           default_expiry=(datetime.date.today() + datetime.timedelta(days=90)).isoformat(),
                           max_expiry=(datetime.date.today() + datetime.timedelta(days=365)).isoformat())


@qbp.route("/exceptions", methods=["POST"])
def exceptions_save():
    pol, rv, _ = quality.load_policy()
    if pol is None:
        abort(404)
    action = request.form.get("action")
    user = g.user["username"]
    if action == "request":
        app_key = request.form.get("app", "").strip()
        rule = request.form.get("rule", "").strip()
        path = request.form.get("path", "").strip() or "*"
        reason = request.form.get("reason", "").strip()
        expires = request.form.get("expires", "").strip()
        if not APP_KEY_RE.match(app_key) or not RULE_RE.match(rule) or len(path) > 200:
            abort(400)
        auth.require_vendor(app_key.split("/")[0])
        if len(reason) < 10:
            flash("예외 사유를 10자 이상 입력하세요 (오탐 근거, 조치 계획 등).", "error")
            return redirect(url_for("quality.exceptions", **request.form.to_dict(flat=True)))
        limit = (datetime.date.today() + datetime.timedelta(days=365)).isoformat()
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", expires) or not (datetime.date.today().isoformat() <= expires <= limit):
            flash("만료일은 오늘부터 1년 이내여야 합니다.", "error")
            return redirect(url_for("quality.exceptions", **request.form.to_dict(flat=True)))
        exc = {"id": uuid.uuid4().hex[:8], "app": app_key, "rule": rule, "path": path,
               "fingerprint": request.form.get("fingerprint", "").strip()[:32] or None,
               "reason": reason[:500], "expires": expires, "requested_by": user, "requested_at": quality.now_iso(),
               "status": "requested"}
        if auth.is_admin() and request.form.get("approve_now"):
            exc.update(status="approved", approved_by=user, approved_at=quality.now_iso())
        exc = {k: v for k, v in exc.items() if v is not None}
        pol["exceptions"].append(exc)
        _save(pol, rv, f"예외 {'등록' if exc['status'] == 'approved' else '요청'} {app_key} {rule}")
        return redirect(url_for("quality.exceptions"))
    if not auth.is_admin():
        abort(403, "예외 승인·반려·삭제는 운영 관리자만 할 수 있습니다.")
    exc_id = request.form.get("id", "")
    exc = next((e for e in pol["exceptions"] if e.get("id") == exc_id), None)
    if exc is None:
        flash("예외를 찾을 수 없습니다(이미 처리됨).", "warn")
        return redirect(url_for("quality.exceptions"))
    if action in ("approve", "reject"):
        exc.update(status="approved" if action == "approve" else "rejected", approved_by=user,
                   approved_at=quality.now_iso(), note=request.form.get("note", "").strip()[:200])
        _save(pol, rv, f"예외 {exc_id} {'승인' if action == 'approve' else '반려'}")
    elif action == "delete":
        pol["exceptions"] = [e for e in pol["exceptions"] if e.get("id") != exc_id]
        _save(pol, rv, f"예외 {exc_id} 삭제")
    else:
        abort(400)
    return redirect(url_for("quality.exceptions"))
