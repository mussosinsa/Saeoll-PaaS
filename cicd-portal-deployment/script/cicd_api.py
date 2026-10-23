#!/usr/bin/env python3
"""REST helpers for the CI/CD portal scripts (Keycloak, GitLab, Harbor).

Standard library only. Settings come from the environment (exported by lib.sh):
  CA_FILE, KEYCLOAK_URL, KEYCLOAK_ADMIN_USERNAME, KEYCLOAK_ADMIN_PASSWORD, KC_REALM,
  GITLAB_URL, GITLAB_TOKEN, HARBOR_URL, REPOSITORY_USERNAME, REPOSITORY_PASSWORD
Results are printed to stdout; progress goes to stderr.
"""
import argparse
import base64
import datetime
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ENV = os.environ


def log(msg):
    print(msg, file=sys.stderr)


def ssl_context():
    ca = ENV.get("CA_FILE", "")
    if ca and os.path.isfile(ca):
        ctx = ssl.create_default_context()
        ctx.load_verify_locations(ca)  # K-PaaS CA in addition to the system store
        return ctx
    return ssl.create_default_context()


CTX = ssl_context()


class HTTPError(Exception):
    def __init__(self, code, body, url):
        super().__init__(f"HTTP {code} {url}: {body[:500]}")
        self.code = code
        self.body = body


def request(method, url, headers=None, data=None, form=None):
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
        with urllib.request.urlopen(req, context=CTX, timeout=60) as resp:
            raw = resp.read().decode() or "null"
            try:
                return resp.status, json.loads(raw)
            except ValueError:
                return resp.status, raw
    except urllib.error.HTTPError as e:
        raise HTTPError(e.code, e.read().decode(errors="replace"), url) from None


def q(value):
    return urllib.parse.quote(str(value), safe="")


# ---------------------------------------------------------------- Keycloak ---
class Keycloak:
    def __init__(self):
        self.base = ENV["KEYCLOAK_URL"].rstrip("/")
        self.realm = ENV["KC_REALM"]
        _, tok = request("POST", f"{self.base}/realms/master/protocol/openid-connect/token", form={
            "grant_type": "password", "client_id": "admin-cli",
            "username": ENV["KEYCLOAK_ADMIN_USERNAME"], "password": ENV["KEYCLOAK_ADMIN_PASSWORD"]})
        self.headers = {"Authorization": "Bearer " + tok["access_token"]}

    def call(self, method, path, data=None):
        return request(method, f"{self.base}/admin/realms/{self.realm}{path}", self.headers, data)[1]

    def client(self, client_id):
        found = self.call("GET", f"/clients?clientId={q(client_id)}")
        return found[0] if found else None

    def ensure_client(self, client_id, redirects, origins, groups_mapper):
        rep = {"clientId": client_id, "name": client_id, "protocol": "openid-connect",
               "publicClient": False, "standardFlowEnabled": True, "directAccessGrantsEnabled": False,
               "serviceAccountsEnabled": False, "redirectUris": redirects, "webOrigins": origins,
               "attributes": {"post.logout.redirect.uris": "+"}}
        current = self.client(client_id)
        if current is None:
            self.call("POST", "/clients", rep)
            current = self.client(client_id)
            log(f"[OK]   Keycloak client created: {client_id}")
        else:
            current.update({k: rep[k] for k in ("redirectUris", "webOrigins")})
            self.call("PUT", f"/clients/{current['id']}", current)
            log(f"[INFO] Keycloak client exists (redirect URIs updated): {client_id}")
        if groups_mapper:
            mappers = self.call("GET", f"/clients/{current['id']}/protocol-mappers/models") or []
            if not any(m.get("name") == "groups" for m in mappers):
                self.call("POST", f"/clients/{current['id']}/protocol-mappers/models", {
                    "name": "groups", "protocol": "openid-connect",
                    "protocolMapper": "oidc-group-membership-mapper",
                    "config": {"full.path": "false", "id.token.claim": "true", "access.token.claim": "true",
                               "userinfo.token.claim": "true", "claim.name": "groups"}})
                log(f"[OK]   groups claim mapper added to {client_id}")
        return self.call("GET", f"/clients/{current['id']}/client-secret")["value"]

    def delete_client(self, client_id):
        current = self.client(client_id)
        if current:
            self.call("DELETE", f"/clients/{current['id']}")
            log(f"[OK]   Keycloak client deleted: {client_id}")

    def ensure_group(self, name):
        for g in self.call("GET", f"/groups?search={q(name)}") or []:
            if g["name"] == name:
                return g["id"]
        self.call("POST", "/groups", {"name": name})
        log(f"[OK]   Keycloak group created: {name}")
        return self.ensure_group(name)

    def add_members(self, group, users):
        gid = self.ensure_group(group)
        for user in users:
            found = [u for u in self.call("GET", f"/users?username={q(user)}&exact=true") or []
                     if u["username"] == user.lower()]
            if not found:
                log(f"[WARN] Keycloak user not found: {user}")
                continue
            self.call("PUT", f"/users/{found[0]['id']}/groups/{gid}")
            log(f"[OK]   {user} -> Keycloak group {group}")


# ------------------------------------------------------------------ GitLab ---
class GitLab:
    def __init__(self):
        self.base = ENV["GITLAB_URL"].rstrip("/") + "/api/v4"
        self.headers = {"PRIVATE-TOKEN": ENV.get("GITLAB_TOKEN", "")}

    def call(self, method, path, data=None):
        return request(method, self.base + path, self.headers, data)[1]

    def get(self, path):
        try:
            return self.call("GET", path)
        except HTTPError as e:
            if e.code == 404:
                return None
            raise

    def wait(self, timeout):
        end = time.time() + timeout
        while True:
            try:
                return self.call("GET", "/version")["version"]
            except Exception as e:  # noqa: BLE001 - keep polling until timeout
                if time.time() > end:
                    raise SystemExit(f"[ERROR] GitLab API not ready: {e}")
                time.sleep(10)

    def ensure_group(self, path, visibility):
        g = self.get(f"/groups/{q(path)}")
        if g is None:
            g = self.call("POST", "/groups", {"name": path, "path": path, "visibility": visibility})
            log(f"[OK]   GitLab group created: {path}")
        return g["id"]

    def project(self, full_path):
        return self.get(f"/projects/{q(full_path)}")

    def ensure_project(self, namespace, path, visibility):
        p = self.project(f"{namespace}/{path}")
        if p is not None:
            return p, False
        ns = self.get(f"/namespaces/{q(namespace)}")
        if ns is None:
            raise SystemExit(f"[ERROR] GitLab namespace not found: {namespace}")
        p = self.call("POST", "/projects", {"name": path, "path": path, "namespace_id": ns["id"],
                                             "visibility": visibility, "initialize_with_readme": True,
                                             "default_branch": "main"})
        log(f"[OK]   GitLab project created: {namespace}/{path}")
        return p, True

    def push_dir(self, project, branch, src, prefix, subs, message, only_missing):
        pid = self.project(project)["id"]
        actions = []
        for root, _, files in os.walk(src):
            for name in sorted(files):
                local = os.path.join(root, name)
                rel = os.path.relpath(local, src).replace(os.sep, "/")
                dest = (prefix.rstrip("/") + "/" + rel).lstrip("/")
                with open(local, encoding="utf-8") as fh:
                    content = fh.read()
                for k, v in subs.items():
                    content = content.replace("{" + k + "}", v)
                current = self.get(f"/projects/{pid}/repository/files/{q(dest)}?ref={q(branch)}")
                if current is None:
                    actions.append({"action": "create", "file_path": dest, "content": content})
                elif not only_missing and base64.b64decode(current["content"]).decode() != content:
                    actions.append({"action": "update", "file_path": dest, "content": content})
        if not actions:
            log(f"[INFO] {project}@{branch}: no changes in {prefix or '/'}")
            return
        self.call("POST", f"/projects/{pid}/repository/commits",
                  {"branch": branch, "commit_message": message, "actions": actions})
        log(f"[OK]   {project}@{branch}: {len(actions)} file(s) committed")

    def ensure_branch(self, project, branch, ref):
        pid = self.project(project)["id"]
        if self.get(f"/projects/{pid}/repository/branches/{q(branch)}") is None:
            self.call("POST", f"/projects/{pid}/repository/branches?branch={q(branch)}&ref={q(ref)}")
            log(f"[OK]   branch {branch} created in {project}")

    def protect_tag(self, project, pattern):
        pid = self.project(project)["id"]
        if self.get(f"/projects/{pid}/protected_tags/{q(pattern)}") is None:
            self.call("POST", f"/projects/{pid}/protected_tags?name={q(pattern)}&create_access_level=40")
            log(f"[OK]   protected tag {pattern} in {project} (Maintainers)")

    def project_token(self, project, name, scopes, level):
        pid = self.project(project)["id"]
        for t in self.call("GET", f"/projects/{pid}/access_tokens") or []:
            if t["name"] == name and t.get("active"):
                self.call("DELETE", f"/projects/{pid}/access_tokens/{t['id']}")
        expires = (datetime.date.today() + datetime.timedelta(days=364)).isoformat()
        t = self.call("POST", f"/projects/{pid}/access_tokens",
                      {"name": name, "scopes": scopes, "access_level": level, "expires_at": expires})
        log(f"[OK]   project access token {name} for {project} (expires {expires})")
        return t["token"]

    def set_variable(self, scope, key, value, masked):
        data = {"key": key, "value": value, "raw": True, "masked": masked, "protected": False}
        if self.get(f"{scope}/variables/{q(key)}") is None:
            self.call("POST", f"{scope}/variables", data)
        else:
            self.call("PUT", f"{scope}/variables/{q(key)}", data)

    def add_members(self, group, users, level):
        gid = self.get(f"/groups/{q(group)}")["id"]
        for user in users:
            found = self.call("GET", f"/users?username={q(user)}") or []
            if not found:
                log(f"[WARN] GitLab user {user} not found - the user must sign in to GitLab once (K-PaaS SSO)")
                continue
            uid = found[0]["id"]
            try:
                self.call("POST", f"/groups/{gid}/members", {"user_id": uid, "access_level": level})
            except HTTPError as e:
                if e.code != 409:
                    raise
                self.call("PUT", f"/groups/{gid}/members/{uid}", {"access_level": level})
            log(f"[OK]   {user} -> GitLab group {group} (access level {level})")

    def create_runner(self, description):
        for r in self.call("GET", "/runners/all?type=instance_type&per_page=100") or []:
            if r.get("description") == description:
                self.call("DELETE", f"/runners/{r['id']}")
        r = self.call("POST", "/user/runners", {"runner_type": "instance_type", "description": description,
                                                "run_untagged": True})
        return r["token"]

    def runners_online(self, description):
        return sum(1 for r in self.call("GET", "/runners/all?status=online&per_page=100") or []
                   if r.get("description") == description)


# ------------------------------------------------------------------ Harbor ---
class Harbor:
    def __init__(self):
        self.base = ENV["HARBOR_URL"].rstrip("/") + "/api/v2.0"
        cred = base64.b64encode(f"{ENV['REPOSITORY_USERNAME']}:{ENV['REPOSITORY_PASSWORD']}".encode()).decode()
        self.headers = {"Authorization": "Basic " + cred}

    def call(self, method, path, data=None):
        return request(method, self.base + path, self.headers, data)[1]

    def ensure_project(self, name, public):
        try:
            self.call("POST", "/projects", {"project_name": name, "public": public})
            log(f"[OK]   Harbor project created: {name}")
        except HTTPError as e:
            if e.code != 409:
                raise

    def robot(self, project, name):
        full = f"robot${project}+{name}"
        page = 1
        while True:
            robots = self.call("GET", f"/robots?page={page}&page_size=100") or []
            for r in robots:
                if r["name"] == full:
                    self.call("DELETE", f"/robots/{r['id']}")
            if len(robots) < 100:
                break
            page += 1
        r = self.call("POST", "/robots", {
            "name": name, "description": f"GitLab CI for {project}", "duration": -1, "level": "project",
            "permissions": [{"kind": "project", "namespace": project, "access": [
                {"resource": "repository", "action": "push"}, {"resource": "repository", "action": "pull"}]}]})
        log(f"[OK]   Harbor robot account {r['name']}")
        return r["name"], r["secret"]


# --------------------------------------------------------------------- CLI ---
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("kc-client"); p.add_argument("client_id"); p.add_argument("--redirect", action="append", default=[])
    p.add_argument("--origin", action="append", default=[]); p.add_argument("--groups-mapper", action="store_true")
    p = sub.add_parser("kc-delete-client"); p.add_argument("client_id")
    p = sub.add_parser("kc-exists"); p.add_argument("client_id")
    p = sub.add_parser("gl-get"); p.add_argument("path")
    p = sub.add_parser("kc-group"); p.add_argument("name"); p.add_argument("--members", default="")
    p = sub.add_parser("gl-wait"); p.add_argument("--timeout", type=int, default=900)
    sub.add_parser("gl-settings")
    p = sub.add_parser("gl-instance-var"); p.add_argument("pairs", nargs="+")
    p = sub.add_parser("gl-group"); p.add_argument("path"); p.add_argument("--visibility", default="private")
    p = sub.add_parser("gl-project"); p.add_argument("namespace"); p.add_argument("path")
    p.add_argument("--visibility", default="private")
    p = sub.add_parser("gl-push-dir"); p.add_argument("project"); p.add_argument("src")
    p.add_argument("--branch", default="main"); p.add_argument("--prefix", default="")
    p.add_argument("--subst", action="append", default=[]); p.add_argument("--message", default="Update by cicd-portal")
    p.add_argument("--only-missing", action="store_true")
    p = sub.add_parser("gl-branch"); p.add_argument("project"); p.add_argument("branch"); p.add_argument("--ref", default="main")
    p = sub.add_parser("gl-protect-tag"); p.add_argument("project"); p.add_argument("pattern")
    p = sub.add_parser("gl-project-token"); p.add_argument("project"); p.add_argument("name")
    p.add_argument("--scopes", required=True); p.add_argument("--level", type=int, required=True)
    p = sub.add_parser("gl-group-var"); p.add_argument("group"); p.add_argument("key"); p.add_argument("--masked", action="store_true")
    p = sub.add_parser("gl-members"); p.add_argument("group"); p.add_argument("users"); p.add_argument("--level", type=int, default=30)
    p = sub.add_parser("gl-runner"); p.add_argument("description")
    p = sub.add_parser("gl-runners-online"); p.add_argument("description")
    p = sub.add_parser("harbor-project"); p.add_argument("name"); p.add_argument("--public", action="store_true")
    p = sub.add_parser("harbor-robot"); p.add_argument("project"); p.add_argument("name")
    a = ap.parse_args()

    try:
        if a.cmd == "kc-client":
            print(Keycloak().ensure_client(a.client_id, a.redirect, a.origin, a.groups_mapper))
        elif a.cmd == "kc-delete-client":
            Keycloak().delete_client(a.client_id)
        elif a.cmd == "kc-exists":
            sys.exit(0 if Keycloak().client(a.client_id) else 1)
        elif a.cmd == "gl-get":
            result = GitLab().get(a.path)
            if result is None:
                sys.exit(1)
            print(json.dumps(result))
        elif a.cmd == "kc-group":
            kc = Keycloak()
            kc.ensure_group(a.name)
            users = [u.strip() for u in a.members.split(",") if u.strip()]
            if users:
                kc.add_members(a.name, users)
        elif a.cmd == "gl-wait":
            print(GitLab().wait(a.timeout))
        elif a.cmd == "gl-settings":
            GitLab().call("PUT", "/application/settings?signup_enabled=false")
        elif a.cmd == "gl-instance-var":
            gl = GitLab()
            for pair in a.pairs:
                k, v = pair.split("=", 1)
                gl.set_variable("/admin/ci", k, v, False)
                log(f"[OK]   instance CI variable {k}")
        elif a.cmd == "gl-group":
            print(GitLab().ensure_group(a.path, a.visibility))
        elif a.cmd == "gl-project":
            project, created = GitLab().ensure_project(a.namespace, a.path, a.visibility)
            print("created" if created else "exists")
        elif a.cmd == "gl-push-dir":
            subs = dict(s.split("=", 1) for s in a.subst)
            GitLab().push_dir(a.project, a.branch, a.src, a.prefix, subs, a.message, a.only_missing)
        elif a.cmd == "gl-branch":
            GitLab().ensure_branch(a.project, a.branch, a.ref)
        elif a.cmd == "gl-protect-tag":
            GitLab().protect_tag(a.project, a.pattern)
        elif a.cmd == "gl-project-token":
            print(GitLab().project_token(a.project, a.name, a.scopes.split(","), a.level))
        elif a.cmd == "gl-group-var":
            gl = GitLab()
            gid = gl.get(f"/groups/{q(a.group)}")["id"]
            gl.set_variable(f"/groups/{gid}", a.key, sys.stdin.read().rstrip("\n"), a.masked)
            log(f"[OK]   group CI variable {a.group}/{a.key}")
        elif a.cmd == "gl-members":
            GitLab().add_members(a.group, [u.strip() for u in a.users.split(",") if u.strip()], a.level)
        elif a.cmd == "gl-runner":
            print(GitLab().create_runner(a.description))
        elif a.cmd == "gl-runners-online":
            print(GitLab().runners_online(a.description))
        elif a.cmd == "harbor-project":
            Harbor().ensure_project(a.name, a.public)
        elif a.cmd == "harbor-robot":
            name, secret = Harbor().robot(a.project, a.name)
            print(name)
            print(secret)
    except HTTPError as e:
        log(f"[ERROR] {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
