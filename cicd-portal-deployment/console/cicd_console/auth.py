"""K-PaaS SSO (Keycloak cp-realm, OpenID Connect authorization code flow) and console permissions.

Roles come from the Keycloak groups claim (client cicd-console has the groups mapper):
  cicd-admins     : every vendor, onboarding / adding applications / databases / members, prod sync
  cicd-<vendor>   : that vendor's applications - builds, dev sync (same rights as in Jenkins and Argo CD)
The ID token is taken straight from the token endpoint over TLS, so its signature is not re-checked
(OpenID Connect Core 3.1.3.7); issuer, audience, expiry and nonce are checked.
"""
import base64
import functools
import hmac
import json
import os
import secrets
import time
import urllib.parse

from flask import abort, current_app, g, redirect, request, session, url_for

from . import services

SESSION_HOURS = 8


def admin_group():
    return os.environ.get("KEYCLOAK_ADMIN_GROUP", "cicd-admins")


def issuer():
    return os.environ["KEYCLOAK_ISSUER"].rstrip("/")


def redirect_uri():
    return f"https://{os.environ['CONSOLE_HOST']}{url_for('auth.callback')}"


def login_url(next_url):
    state, nonce = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
    session["oidc"] = {"state": state, "nonce": nonce, "next": next_url}
    params = {"client_id": os.environ["OIDC_CLIENT_ID"], "response_type": "code", "scope": "openid profile email",
              "redirect_uri": redirect_uri(), "state": state, "nonce": nonce}
    return f"{issuer()}/protocol/openid-connect/auth?{urllib.parse.urlencode(params)}"


def _claims(id_token):
    payload = id_token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


def finish_login(args):
    pending = session.pop("oidc", None)
    if not pending or not hmac.compare_digest(pending["state"], args.get("state", "")):
        abort(400, "로그인 요청이 만료되었습니다. 다시 로그인하세요.")
    if "error" in args:
        abort(403, f"Keycloak: {args.get('error_description') or args['error']}")
    client_id = os.environ["OIDC_CLIENT_ID"]
    token, _ = services.http("POST", f"{issuer()}/protocol/openid-connect/token", form={
        "grant_type": "authorization_code", "code": args.get("code", ""), "redirect_uri": redirect_uri(),
        "client_id": client_id, "client_secret": os.environ["OIDC_CLIENT_SECRET"]})
    claims = _claims(token["id_token"])
    aud = claims.get("aud")
    if (claims.get("iss") != issuer() or client_id not in (aud if isinstance(aud, list) else [aud])
            or claims.get("exp", 0) < time.time() or claims.get("nonce") != pending["nonce"]):
        abort(403, "ID 토큰 검증에 실패했습니다.")
    session.clear()
    session.permanent = True
    session["user"] = {"username": claims.get("preferred_username") or claims.get("sub"),
                       "name": claims.get("name") or claims.get("preferred_username") or "",
                       "groups": sorted(gr.lstrip("/") for gr in claims.get("groups") or []),
                       "expires": time.time() + SESSION_HOURS * 3600}
    session["csrf"] = secrets.token_urlsafe(24)
    current_app.logger.info("login %s groups=%s", session["user"]["username"], session["user"]["groups"])
    nxt = pending.get("next") or "/"
    return nxt if nxt.startswith("/") and not nxt.startswith("//") else "/"


def logout_url():
    params = {"client_id": os.environ["OIDC_CLIENT_ID"],
              "post_logout_redirect_uri": f"https://{os.environ['CONSOLE_HOST']}/"}
    return f"{issuer()}/protocol/openid-connect/logout?{urllib.parse.urlencode(params)}"


# ---------------------------------------------------------------- permissions ---
def current_user():
    user = session.get("user")
    if not user or user.get("expires", 0) < time.time():
        return None
    return user


def is_admin(user=None):
    user = user or g.user
    return bool(user) and admin_group() in user["groups"]


def user_vendors(user=None):
    """Vendor ids the user may see; None = all (admins)."""
    user = user or g.user
    if is_admin(user):
        return None
    return sorted(gr[5:] for gr in user["groups"] if gr.startswith("cicd-") and gr != admin_group())


def can_view(vendor_name):
    allowed = user_vendors()
    return allowed is None or vendor_name in allowed


def require_vendor(vendor_name):
    if not can_view(vendor_name):
        abort(403, f"업체 {vendor_name}에 대한 권한이 없습니다 (Keycloak 그룹 cicd-{vendor_name}).")


def admin_required(view):
    @functools.wraps(view)
    def wrapper(*args, **kwargs):
        if not is_admin():
            abort(403, f"운영 관리자({admin_group()} 그룹)만 사용할 수 있습니다.")
        return view(*args, **kwargs)
    return wrapper


def check_csrf():
    if request.method in ("POST", "PUT", "DELETE"):
        sent = request.form.get("csrf_token") or request.headers.get("X-CSRF-Token") or ""
        if not session.get("csrf") or not hmac.compare_digest(sent, session["csrf"]):
            abort(400, "요청이 만료되었습니다(CSRF). 화면을 새로 고친 뒤 다시 시도하세요.")
