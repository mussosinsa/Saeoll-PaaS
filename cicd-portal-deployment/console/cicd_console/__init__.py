"""CI/CD console: web UI for the CI/CD portal (cicd-portal-deployment), based on the screens of ap-pipeline-ui."""
import datetime
import logging
import os

from flask import Flask, g, redirect, render_template, request, session, url_for
from werkzeug.exceptions import HTTPException

from . import auth, config, services
from .kube import KubeError

TZ = datetime.timezone(datetime.timedelta(hours=float(os.environ.get("CONSOLE_TZ_OFFSET", "9"))))

STATUS_LABELS = {
    "success": "성공", "failed": "실패", "running": "실행 중", "pending": "대기", "canceled": "중지됨",
    "unstable": "불안정", "skipped": "건너뜀", "manual": "수동 대기", "unknown": "알 수 없음",
    "Synced": "동기화됨", "OutOfSync": "변경 있음", "Unknown": "알 수 없음",
    "Healthy": "정상", "Progressing": "진행 중", "Degraded": "오류", "Missing": "없음", "Suspended": "중지",
    "pass": "통과", "warn": "경고", "fail": "차단", "none": "결과 없음",
    "critical": "Critical", "high": "High", "medium": "Medium", "low": "Low", "info": "Info",
    "report": "경고 모드", "enforce": "차단 모드",
}


def create_app():
    config.load()
    app = Flask(__name__)
    app.secret_key = os.environ.get("CONSOLE_SECRET_KEY") or os.urandom(32)
    app.config.update(SESSION_COOKIE_NAME="cicd_console", SESSION_COOKIE_HTTPONLY=True,
                      SESSION_COOKIE_SAMESITE="Lax",
                      SESSION_COOKIE_SECURE=os.environ.get("CONSOLE_INSECURE_COOKIE") != "1",
                      PERMANENT_SESSION_LIFETIME=datetime.timedelta(hours=auth.SESSION_HOURS))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    app.logger.setLevel(logging.INFO)

    from . import quality_views  # noqa: PLC0415
    from .views import auth_bp, bp  # noqa: PLC0415
    app.register_blueprint(auth_bp)
    app.register_blueprint(bp)
    quality_views.register(app)

    @app.route("/healthz")
    def healthz():
        return "ok"

    @app.before_request
    def require_login():
        if request.endpoint in ("healthz", "static") or request.blueprint == "auth":
            return None
        g.user = auth.current_user()
        if g.user is None:
            if request.path.startswith("/api/"):
                return {"error": "login required"}, 401
            return redirect(url_for("auth.login", next=request.full_path.rstrip("?")))
        auth.check_csrf()
        return None

    @app.context_processor
    def globals_():
        user = getattr(g, "user", None)
        return {"user": user, "is_admin": auth.is_admin(user) if user else False,
                "csrf_token": session.get("csrf", ""), "sources": config.sources(),
                "admin_group": auth.admin_group(), "host_domain": os.environ.get("HOST_DOMAIN", ""),
                "status_label": lambda s: STATUS_LABELS.get(s, s or "-")}

    @app.template_filter("dt")
    def fmt_dt(value):
        return value.astimezone(TZ).strftime("%Y-%m-%d %H:%M:%S") if value else "-"

    @app.template_filter("ago")
    def fmt_ago(value):
        if not value:
            return "-"
        sec = (datetime.datetime.now(datetime.timezone.utc) - value).total_seconds()
        for unit, size in (("일", 86400), ("시간", 3600), ("분", 60)):
            if sec >= size:
                return f"{int(sec // size)}{unit} 전"
        return "방금"

    @app.template_filter("dur")
    def fmt_dur(sec):
        if not sec:
            return "-"
        sec = int(sec)
        return f"{sec // 60}분 {sec % 60}초" if sec >= 60 else f"{sec}초"

    @app.errorhandler(HTTPException)
    def http_error(e):
        if request.path.startswith("/api/"):
            return {"error": e.description}, e.code
        return render_template("error.html", code=e.code, message=e.description), e.code

    @app.errorhandler(services.BackendError)
    @app.errorhandler(KubeError)
    def backend_error(e):
        app.logger.warning("backend error on %s: %s", request.path, e)
        return render_template("error.html", code=502, message=str(e)), 502

    return app
