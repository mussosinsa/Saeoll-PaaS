#!/usr/bin/env python3
"""REST helpers for the CI/CD portal scripts (Keycloak, GitLab, Harbor).

Standard library only. Settings come from the environment (exported by lib.sh):
  CA_FILE, KEYCLOAK_URL, KEYCLOAK_ADMIN_USERNAME, KEYCLOAK_ADMIN_PASSWORD, KC_REALM,
  GITLAB_URL, GITLAB_TOKEN, HARBOR_URL, REPOSITORY_USERNAME, REPOSITORY_PASSWORD,
  SCM_URL, SCM_ADMIN_USER, SCM_ADMIN_PASSWORD, JENKINS_URL, JENKINS_USER, JENKINS_API_TOKEN
Results are printed to stdout; progress goes to stderr.
"""
import argparse
import base64
import datetime
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from xml.sax.saxutils import escape as xml_escape

ENV = os.environ


def log(msg):
    print(msg, file=sys.stderr)


def ssl_context():
    ca = ENV.get("CA_FILE", "")
    if ca and os.path.isfile(ca):
        ctx = ssl.create_default_context()
        try:
            ctx.load_verify_locations(ca)  # K-PaaS CA in addition to the system store
        except ssl.SSLError as e:
            log(f"[WARN] CA_FILE {ca} is not a valid certificate ({e.reason}); using the system CAs only")
        return ctx
    return ssl.create_default_context()


CTX = ssl_context()


class HTTPError(Exception):
    def __init__(self, code, body, url):
        super().__init__(f"HTTP {code} {url}: {body[:500]}")
        self.code = code
        self.body = body


def request(method, url, headers=None, data=None, form=None, xml=None):
    headers = dict(headers or {})
    body = None
    if xml is not None:
        body = xml.encode()
        headers["Content-Type"] = "application/xml"
    elif form is not None:
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
            # logout redirects must be allowed too (Keycloak rejects post_logout_redirect_uri otherwise)
            current.setdefault("attributes", {}).setdefault("post.logout.redirect.uris", "+")
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

    def ensure_user(self, username, email, password):
        if self.call("GET", f"/users?username={q(username)}&exact=true"):
            return False
        self.call("POST", "/users", {"username": username, "email": email, "emailVerified": True, "enabled": True,
                                     "firstName": username, "lastName": "CI",
                                     "attributes": {"cicd-portal-created": ["true"]},
                                     "credentials": [{"type": "password", "value": password, "temporary": False}]})
        log(f"[OK]   Keycloak user created: {username}")
        return True

    def group_members(self, group):
        for g in self.call("GET", f"/groups?search={q(group)}") or []:
            if g["name"] == group:
                return [u["username"] for u in self.call("GET", f"/groups/{g['id']}/members?max=500") or []]
        return []

    def delete_group(self, group):
        """Delete the group (users are kept); returns its former members."""
        for g in self.call("GET", f"/groups?search={q(group)}") or []:
            if g["name"] == group:
                members = [u["username"] for u in self.call("GET", f"/groups/{g['id']}/members?max=500") or []]
                self.call("DELETE", f"/groups/{g['id']}")
                log(f"[OK]   Keycloak group deleted: {group} (users kept: {', '.join(members) or 'none'})")
                return members
        log(f"[INFO] Keycloak group not found: {group}")
        return []

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

    def ensure_project(self, namespace, path, visibility, empty=False):
        p = self.project(f"{namespace}/{path}")
        if p is not None:
            return p, False
        ns = self.get(f"/namespaces/{q(namespace)}")
        if ns is None:
            raise SystemExit(f"[ERROR] GitLab namespace not found: {namespace}")
        p = self.call("POST", "/projects", {"name": path, "path": path, "namespace_id": ns["id"],
                                             "visibility": visibility, "initialize_with_readme": not empty,
                                             "default_branch": "main"})
        log(f"[OK]   GitLab project created: {namespace}/{path}")
        return p, True

    def push_dir(self, project, branch, src, prefix, subs, message, only_missing, exclude=()):
        pid = self.project(project)["id"]
        actions = []
        for root, dirs, files in os.walk(src):
            dirs[:] = [d for d in dirs if d != ".git"]
            for name in sorted(files):
                if name in exclude:
                    continue
                local = os.path.join(root, name)
                rel = os.path.relpath(local, src).replace(os.sep, "/")
                dest = (prefix.rstrip("/") + "/" + rel).lstrip("/")
                with open(local, encoding="utf-8") as fh:
                    content = fh.read()
                for k, v in subs.items():
                    # {KEY} only - "${KEY}" belongs to the file (Dockerfile ARG, shell, CI variables)
                    content = re.sub(r"(?<!\$)\{" + re.escape(k) + r"\}", lambda m, v=v: v, content)
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

    def security(self, name, prevent):
        """Scan on push; prevent (e.g. 'critical') refuses pulls of images with vulnerabilities of that severity."""
        meta = {"auto_scan": "true", "prevent_vul": "true" if prevent else "false"}
        if prevent:
            meta["severity"] = prevent
        self.call("PUT", f"/projects/{self.project_id(name)}", {"metadata": meta})
        log(f"[OK]   Harbor project {name}: scan on push" + (f", pulls blocked from severity {prevent}" if prevent else ""))

    def immutable(self, project, pattern):
        """Tag immutability rule: a pushed tag matching pattern (e.g. v*) cannot be overwritten."""
        pid = self.project_id(project)
        for r in self.call("GET", f"/projects/{pid}/immutabletagrules") or []:
            if any(t.get("pattern") == pattern for t in r.get("tag_selectors") or []):
                log(f"[INFO] Harbor project {project}: tags {pattern} already immutable")
                return
        self.call("POST", f"/projects/{pid}/immutabletagrules", {
            "disabled": False, "action": "immutable", "template": "immutable_template",
            "scope_selectors": {"repository": [{"kind": "doublestar", "decoration": "repoMatches", "pattern": "**"}]},
            "tag_selectors": [{"kind": "doublestar", "decoration": "matches", "pattern": pattern}]})
        log(f"[OK]   Harbor project {project}: tags {pattern} immutable")

    def delete_repository(self, project, repo):
        try:
            self.call("DELETE", f"/projects/{q(project)}/repositories/{q(q(repo))}")
            log(f"[OK]   Harbor repository deleted: {project}/{repo}")
        except HTTPError as e:
            if e.code != 404:
                raise
            log(f"[INFO] Harbor repository not found: {project}/{repo}")

    def delete_project(self, project):
        """Delete all repositories, the robots and the project."""
        try:
            pid = self.project_id(project)
        except SystemExit:
            log(f"[INFO] Harbor project not found: {project}")
            return
        while True:
            repos = self.call("GET", f"/projects/{q(project)}/repositories?page_size=100") or []
            if not repos:
                break
            for r in repos:
                self.delete_repository(project, r["name"].split("/", 1)[1])
        for name in ("cicd", "push", "upload"):
            for r in self.find_robots(project, name):
                self.call("DELETE", f"/robots/{r['id']}")
        self.call("DELETE", f"/projects/{pid}")
        log(f"[OK]   Harbor project deleted: {project}")

    def robots_enabled(self, project, enabled):
        """Enable / disable the project robots (cicd, push, upload) without changing their secrets."""
        for name in ("cicd", "push", "upload"):
            for r in self.find_robots(project, name):
                full = self.call("GET", f"/robots/{r['id']}")
                if bool(full.get("disable")) == (not enabled):
                    continue
                full["disable"] = not enabled
                self.call("PUT", f"/robots/{r['id']}", full)
                log(f"[OK]   Harbor robot {full.get('name')} {'enabled' if enabled else 'disabled'}")

    def tag_digest(self, project, repo, tag):
        """Digest of <project>/<repo>:<tag>, '' when the tag (or the repository) does not exist yet."""
        try:
            art = self.call("GET", f"/projects/{q(project)}/repositories/{q(q(repo))}/artifacts/{q(tag)}")
        except HTTPError as e:
            if e.code == 404:
                return ""
            raise
        return (art or {}).get("digest", "")

    def project_id(self, project):
        for p in self.call("GET", f"/projects?name={q(project)}&page_size=100") or []:
            if p.get("name") == project:
                return p["project_id"]
        raise SystemExit(f"[ERROR] Harbor project not found: {project}")

    def find_robots(self, project, name):
        """Project robots are only listed with a Level/ProjectID query; plain /robots is a fallback."""
        wanted = {f"robot${project}+{name}", f"{project}+{name}"}
        pid = self.project_id(project)
        found = {}
        for query in (f"/robots?q={q(f'Level=project,ProjectID={pid}')}&page_size=100", "/robots?page_size=100"):
            try:
                robots = self.call("GET", query) or []
            except HTTPError:
                continue
            for r in robots:
                if r.get("name") in wanted or str(r.get("name", "")).endswith(f"{project}+{name}"):
                    found[r["id"]] = r
        return list(found.values())

    def robot(self, project, name):
        """(Re)create the project robot so a fresh secret is known (secrets cannot be read back)."""
        for r in self.find_robots(project, name):
            self.call("DELETE", f"/robots/{r['id']}")
            log(f"[INFO] Harbor robot account {r['name']} replaced (new secret)")
        body = {"name": name, "description": f"CI/CD portal for {project}", "duration": -1, "level": "project",
                "permissions": [{"kind": "project", "namespace": project, "access": [
                    {"resource": "repository", "action": "push"}, {"resource": "repository", "action": "pull"}]}]}
        try:
            r = self.call("POST", "/robots", body)
        except HTTPError as e:
            if e.code != 409:
                raise
            raise SystemExit(f"[ERROR] Harbor robot {project}+{name} exists but could not be found to replace it. "
                             f"Delete it in Harbor (Projects > {project} > Robot Accounts) and re-run.")
        log(f"[OK]   Harbor robot account {r['name']}")
        return r["name"], r["secret"]


# ------------------------------------------------- SCM-Manager 1.x (K-PaaS) ---
class SCM:
    """SCM-Manager 1.x REST API of K-PaaS source control. Application repositories created here are also
    registered in the K-PaaS source control DB (ScmDB) so that scm.<domain> lists them."""
    LEVELS = {"READ": 1, "WRITE": 2, "OWNER": 3}

    def __init__(self):
        self.base = ENV["SCM_URL"].rstrip("/") + "/api/rest"
        cred = base64.b64encode(f"{ENV['SCM_ADMIN_USER']}:{ENV['SCM_ADMIN_PASSWORD']}".encode()).decode()
        self.headers = {"Authorization": "Basic " + cred}

    def repositories(self):
        return request("GET", self.base + "/repositories.json", self.headers)[1] or []

    def create(self, repo, user, level, description):
        """Create a git repository directly in SCM-Manager (used for the machine-managed gitops
        repository; it is not registered in the K-PaaS source control DB, so scm.<domain> does not list it)."""
        if any(r.get("name") == repo for r in self.repositories()):
            return False
        perms = [{"name": user, "type": level, "groupPermission": False}] if user else []
        request("POST", self.base + "/repositories", self.headers,
                {"name": repo, "type": "git", "public": False, "description": description, "permissions": perms})
        log(f"[OK]   SCM repository created in SCM-Manager: {repo}" + (f" ({user}: {level})" if user else ""))
        return True

    def users(self):
        return {u.get("name") for u in request("GET", self.base + "/users.json", self.headers)[1] or []}

    def ensure_app_repo(self, repo, description, wanted):
        """Create the application repository if missing and add the wanted permissions {user: level}
        (existing permissions are kept, never lowered). Returns the SCM-Manager repository."""
        found = [r for r in self.repositories() if r.get("name") == repo]
        if not found:
            request("POST", self.base + "/repositories", self.headers,
                    {"name": repo, "type": "git", "public": False, "description": description,
                     "permissions": [{"name": u, "type": lv, "groupPermission": False} for u, lv in wanted.items()]})
            log(f"[OK]   SCM repository created: {repo} (" + ", ".join(f"{u}: {lv}" for u, lv in wanted.items()) + ")")
            found = [r for r in self.repositories() if r.get("name") == repo]
            if not found:
                raise SystemExit(f"[ERROR] SCM repository {repo} not found after creation")
            return found[0]
        current = found[0]
        perms = list(current.get("permissions") or [])
        changed = []
        for user, level in wanted.items():
            have = [p for p in perms if p.get("name") == user and not p.get("groupPermission")]
            if have and max(self.LEVELS.get(p.get("type", ""), 0) for p in have) >= self.LEVELS[level]:
                continue
            perms = [p for p in perms if not (p.get("name") == user and not p.get("groupPermission"))]
            perms.append({"name": user, "type": level, "groupPermission": False})
            changed.append(f"{user}: {level}")
        if changed:
            current["permissions"] = perms
            request("PUT", f"{self.base}/repositories/{q(current['id'])}", self.headers, current)
            log(f"[OK]   SCM repository {repo}: permissions added ({', '.join(changed)})")
        else:
            log(f"[INFO] SCM repository exists: {repo}")
        return current

    def check(self, repo, user, level):
        found = [r for r in self.repositories() if r.get("name") == repo]
        if not found:
            return f"repository '{repo}' not found - create it in scm.<domain> (레파지토리 신규생성, type Git)"
        if found[0].get("type", "git") != "git":
            return f"repository '{repo}' is {found[0].get('type')}, not git"
        if user:
            perms = [p for p in found[0].get("permissions") or []
                     if p.get("name") == user and not p.get("groupPermission")]
            have = max((self.LEVELS.get(p.get("type", ""), 0) for p in perms), default=0)
            if have < self.LEVELS[level]:
                return (f"user '{user}' needs {level} on '{repo}' - add as 참여자 "
                        f"({'쓰기' if level != 'READ' else '보기'} 권한) in scm.<domain>")
        return ""


# ------------------------------------------- K-PaaS source control DB (cp_scm) ---
class ScmDB:
    """Registers a repository created through the SCM-Manager API in the K-PaaS source control DB so that
    scm.<domain> lists it with its 참여자. The DB layout is not documented: every value is derived from
    repositories created in scm.<domain> (template rows) and nothing is written when that is not possible."""
    NAME_RE = re.compile(r"^[A-Za-z0-9._@-]{1,128}$")
    TIME_FORMATS = {12: "%Y%m%d%H%M", 8: "%Y%m%d", 14: "%Y%m%d%H%M%S"}

    def __init__(self):
        self.password = ENV.get("DATABASE_USER_PASSWORD", "")
        if not self.password:
            raise SystemExit("[ERROR] DATABASE_USER_PASSWORD (K-PaaS MariaDB root) is not set")
        out = subprocess.run(["kubectl", "-n", "mariadb", "get", "pods", "-l", "app.kubernetes.io/name=mariadb",
                              "-o", "name"], capture_output=True, text=True, timeout=30)
        self.pod = (out.stdout.split() or ["pod/mariadb-0"])[0].split("/", 1)[1]

    def sql(self, statement):
        """Rows of a statement on cp_scm (tab separated, no header), as the MariaDB root (password on stdin)."""
        script = ('IFS= read -r MYSQL_PWD; export MYSQL_PWD; c=$(command -v mariadb || command -v mysql); '
                  '"$c" -uroot -N -B cp_scm')
        out = subprocess.run(["kubectl", "-n", "mariadb", "exec", "-i", self.pod, "--", "sh", "-c", script],
                             input=f"{self.password}\n{statement}\n", capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            raise SystemExit(f"[ERROR] cp_scm: {out.stderr.strip()[:300]}")
        return [line.split("\t") for line in out.stdout.splitlines() if line]

    @staticmethod
    def lit(value):
        return "'" + str(value).replace("\\", "\\\\").replace("'", "''") + "'"

    @classmethod
    def time_format(cls, sample):
        """Format of SC_REPOSITORY.CREATED_TIME (varchar(12)) from a row created in scm.<domain>."""
        return cls.TIME_FORMATS.get(len(sample)) if sample.isdigit() else None

    @staticmethod
    def scm_key(template, scm_repos):
        """Which SCM-Manager field SC_REPOSITORY.REPO_SCM_ID holds ('id' or 'name'), learned from the rows."""
        by_id = {r.get("id"): r for r in scm_repos}
        for repo_scm_id, *_, repo_name in template:
            if repo_scm_id in by_id and by_id[repo_scm_id].get("name") == repo_name:
                return "id"
            if repo_scm_id == repo_name and any(r.get("name") == repo_name for r in scm_repos):
                return "name"
        return None

    def register(self, scm_repo, scm_repos, description, owner, wanted):
        """Insert SC_REPOSITORY / REPO_PERMITION rows like scm.<domain> does. Returns (registered, pending users)."""
        name = scm_repo["name"]
        template = self.sql("SELECT REPO_SCM_ID, INSTANCE_ID, OWNER_USER_ID, CREATED_TIME, REPO_NAME "
                            "FROM SC_REPOSITORY ORDER BY REPO_NO DESC LIMIT 20")
        if not template:
            log("[WARN] cp_scm.SC_REPOSITORY is empty: create one repository in scm.<domain> first (template) - "
                f"{name} works for git/Jenkins but is not listed in scm.<domain>")
            return False, []
        key = self.scm_key(template, scm_repos)
        fmt = self.time_format(template[0][3])
        if key is None or fmt is None:
            log(f"[WARN] cp_scm layout not recognised (REPO_SCM_ID {template[0][0]!r}, CREATED_TIME {template[0][3]!r})"
                f" - {name} is not listed in scm.<domain>; add it there by hand if needed")
            return False, []
        instance, template_owner = template[0][1], template[0][2]
        owner = owner if owner and self.NAME_RE.match(owner) else template_owner
        existing = self.sql(f"SELECT REPO_NO FROM SC_REPOSITORY WHERE REPO_NAME={self.lit(name)}")
        if existing:
            repo_no = existing[0][0]
            log(f"[INFO] {name} is already listed in scm.<domain>")
        else:
            created = datetime.datetime.now().strftime(fmt)
            self.sql("INSERT INTO SC_REPOSITORY (REPO_SCM_ID, REPO_NAME, REPO_DESC, INSTANCE_ID, OWNER_USER_ID, "
                     f"CREATE_USER_ID, CREATED_TIME) VALUES ({self.lit(scm_repo[key])}, {self.lit(name)}, "
                     f"{self.lit(description[:255])}, {self.lit(instance)}, {self.lit(owner)}, {self.lit(owner)}, "
                     f"{self.lit(created)})")
            repo_no = self.sql(f"SELECT REPO_NO FROM SC_REPOSITORY WHERE REPO_NAME={self.lit(name)}")[0][0]
            log(f"[OK]   {name} registered in scm.<domain> (owner {owner})")
        values = {row[0] for row in self.sql("SELECT DISTINCT PERMISSION FROM REPO_PERMITION")}
        value_of = {v.upper(): v for v in values}
        # scm.<domain> stores the SCM-Manager permission names (OWNER, WRITE seen in the DB); a level that no
        # repository uses yet (e.g. READ = 보기) is written the same way
        if values and set(value_of) <= set(SCM.LEVELS):
            for level in SCM.LEVELS:
                value_of.setdefault(level, level)
        if not all(level in value_of for level in set(wanted.values()) | {"OWNER"}):
            log(f"[WARN] REPO_PERMITION values {sorted(values)} are not SCM-Manager permission names - "
                f"참여자 of {name} not registered; add them in scm.<domain>")
            return True, []
        # like scm.<domain>: the owner (creator) is a 참여자 with OWNER
        wanted = {owner: "OWNER", **{u: lv for u, lv in wanted.items() if u != owner}}
        have = {row[0] for row in self.sql(f"SELECT USER_ID FROM REPO_PERMITION WHERE REPO_NO={int(repo_no)}")}
        known = {row[0] for row in self.sql("SELECT DISTINCT USER_ID FROM SC_INSTANCE_USER")}
        pending = []
        for user, level in wanted.items():
            if user not in known:
                pending.append(user)          # no scm.<domain> account until the first login
            elif user not in have:
                self.sql(f"INSERT INTO REPO_PERMITION (REPO_NO, USER_ID, PERMISSION) VALUES "
                         f"({int(repo_no)}, {self.lit(user)}, {self.lit(value_of[level])})")
                log(f"[OK]   참여자 {user}: {dict(OWNER='관리', WRITE='쓰기', READ='보기')[level]} 권한")
        return True, pending


def _scm_restart():
    """Restart SCM-Manager (cp-source-control-manager) so it lets go of open git pack files, then wait for its API."""
    ns = ENV.get("SCM_NAMESPACE", "cp-source-control")
    out = subprocess.run(["kubectl", "-n", ns, "get", "deployments,statefulsets", "-o", "name"],
                         capture_output=True, text=True, timeout=60)
    names = [n for n in out.stdout.split() if "manager" in n.split("/", 1)[-1]]
    if len(names) != 1:
        log(f"[WARN] SCM-Manager workload not found in namespace {ns} ({out.stderr.strip()[:200] or names})")
        return False
    log(f"[INFO] Restarting SCM-Manager ({ns}/{names[0]}): git access pauses for about a minute")
    for cmd in (["rollout", "restart", names[0]], ["rollout", "status", names[0], "--timeout=300s"]):
        r = subprocess.run(["kubectl", "-n", ns, *cmd], capture_output=True, text=True, timeout=330)
        if r.returncode != 0:
            log(f"[WARN] kubectl {' '.join(cmd)}: {r.stderr.strip()[:300]}")
            return False
    scm = SCM()
    for _ in range(24):
        try:
            scm.repositories()
            log("[OK]   SCM-Manager restarted")
            return True
        except (HTTPError, urllib.error.URLError, OSError):
            time.sleep(5)
    log("[WARN] SCM-Manager API did not answer after the restart")
    return False


def scm_delete_repos(repos, restart=False):
    """Delete repositories from SCM-Manager and from the K-PaaS source control DB (scm.<domain> list).
    SCM-Manager 1.x deletes the git directory itself; on NFS a pack file it still has open (JGit cache) leaves a
    .nfs* file behind: HTTP 500 "could not delete file .../objects/pack". It is retried; with restart=True
    SCM-Manager is restarted once (releases the files) and the rest is retried. Returns the repos not deleted."""
    scm = SCM()
    failed = []
    restarted = False
    for repo in repos:
        done = False
        for attempt in range(1, 4):
            found = [r for r in scm.repositories() if r.get("name") == repo]
            if not found:
                done = True
                if attempt == 1:
                    log(f"[INFO] SCM repository not found: {repo}")
                break
            try:
                request("DELETE", f"{scm.base}/repositories/{q(found[0]['id'])}", scm.headers)
                log(f"[OK]   SCM repository deleted: {repo}")
                done = True
                break
            except HTTPError as e:
                if e.code != 500:
                    raise
                if attempt < 3:
                    log(f"[INFO] SCM-Manager could not delete {repo} yet (files in use) - retry in 20s")
                    time.sleep(20)
                elif restart and not restarted:
                    restarted = True
                    if _scm_restart():
                        try:
                            request("DELETE", f"{scm.base}/repositories/{q(found[0]['id'])}", scm.headers)
                            log(f"[OK]   SCM repository deleted: {repo}")
                            done = True
                        except HTTPError as e2:
                            log(f"[WARN] {repo}: {str(e2)[:200]}")
                else:
                    log(f"[WARN] SCM-Manager could not delete {repo}: {str(e)[:200]}")
        if not done:
            failed.append(repo)
            continue
        if not ENV.get("DATABASE_USER_PASSWORD"):
            log(f"[WARN] DATABASE_USER_PASSWORD not set: {repo} may still be listed in scm.<domain>")
            continue
        db = ScmDB()
        for row in db.sql(f"SELECT REPO_NO FROM SC_REPOSITORY WHERE REPO_NAME={db.lit(repo)}"):
            db.sql(f"DELETE FROM REPO_PERMITION WHERE REPO_NO={int(row[0])}")
            db.sql(f"DELETE FROM SC_REPOSITORY WHERE REPO_NO={int(row[0])}")
            log(f"[OK]   {repo} removed from the scm.<domain> list")
    for repo in failed:
        log(f"[TODO] SCM repository {repo} was not deleted (files in use on NFS). Either run the deletion again with\n"
            f"       'SCM-Manager 재시작 허용' (SCM_RESTART=1), or restart SCM-Manager yourself\n"
            f"       (kubectl -n {ENV.get('SCM_NAMESPACE', 'cp-source-control')} rollout restart deploy/<manager>) and delete {repo}\n"
            f"       in the SCM-Manager admin UI (scm-manager.<domain>, Repositories > Remove).")
    return failed


def scm_vendor_repos(vendor, protect):
    """SCM repositories of a vendor: <vendor>-gitops and <vendor>-<app> (SCM-Manager and the scm.<domain> DB),
    without the repositories of other vendors whose names start the same way (protect)."""
    names = {r.get("name", "") for r in SCM().repositories()}
    if ENV.get("DATABASE_USER_PASSWORD"):
        names |= {row[0] for row in ScmDB().sql("SELECT REPO_NAME FROM SC_REPOSITORY")}
    others = [p for p in protect if p.endswith("-")]     # other vendors named <vendor>-...: all their repositories
    return sorted(n for n in names if n.startswith(f"{vendor}-") and n not in protect
                  and not any(n.startswith(p) for p in others))


def vendor_accounts(vendor, ci_user, extra, apply):
    """Accounts of a vendor to delete with it (Keycloak cp-realm, SCM-Manager, scm.<domain> DB): the portal CI
    account jenkins-<vendor>, the members of cicd-<vendor> and the extra users - except operators, protected
    accounts and users that belong to another group (another vendor, a K-PaaS group). Prints the decisions."""
    kc = Keycloak()
    group = f"cicd-{vendor}"
    admin_group = ENV.get("KEYCLOAK_ADMIN_GROUP", "cicd-admins")
    protected = {"admin", "scmadmin", ENV.get("KEYCLOAK_ADMIN_USERNAME", ""), ENV.get("SCM_ADMIN_USER", "")} - {""}
    candidates = {}
    if ci_user:
        candidates[ci_user.lower()] = "CI account"
    for m in kc.group_members(group):
        candidates.setdefault(m.lower(), "member")
    for e in extra:
        candidates.setdefault(e.strip().lower(), "listed")
    delete = []
    for name, why in sorted(candidates.items()):
        if not name:
            continue
        found = [u for u in kc.call("GET", f"/users?username={q(name)}&exact=true") or [] if u["username"] == name]
        if name in protected:
            log(f"  - keep  : account {name} (protected)")
            continue
        created = bool(found) and "true" in ((found[0].get("attributes") or {}).get("cicd-portal-created") or [])
        if why == "CI account" and name != f"jenkins-{vendor}" and not created:
            log(f"  - keep  : account {name} (an existing account used as the CI account)")
            continue
        if found:
            groups = [g["name"] for g in kc.call("GET", f"/users/{found[0]['id']}/groups") or []]
            others = [g for g in groups if g != group]
            if admin_group in groups or others:
                log(f"  - keep  : account {name} ({why}; also in {', '.join(others)})")
                continue
        log(f"  - delete: account {name} ({why}) - Keycloak{'' if found else ' (not found)'}, SCM-Manager, scm.<domain>")
        delete.append((name, found[0]["id"] if found else None))
    if not apply:
        return [n for n, _ in delete]
    scm = SCM() if ENV.get("SCM_ADMIN_PASSWORD") else None
    scm_users = scm.users() if scm else set()
    db = ScmDB() if ENV.get("DATABASE_USER_PASSWORD") else None
    db_tables = []
    if db:
        for table in ("REPO_PERMITION", "SC_INSTANCE_USER", "SC_USER"):
            try:
                if any(col[0].upper() == "USER_ID" for col in db.sql(f"SHOW COLUMNS FROM {table}")):
                    db_tables.append(table)
            except SystemExit:
                pass
    for name, uid in delete:
        if uid:
            kc.call("DELETE", f"/users/{uid}")
            log(f"[OK]   Keycloak user deleted: {name}")
        if name in scm_users:
            request("DELETE", f"{scm.base}/users/{q(name)}", scm.headers)
            log(f"[OK]   SCM-Manager user deleted: {name}")
        for table in db_tables:
            db.sql(f"DELETE FROM {table} WHERE USER_ID={db.lit(name)}")
        if db_tables:
            log(f"[OK]   {name} removed from scm.<domain> ({', '.join(db_tables)})")
    return [n for n, _ in delete]


def policy_forget(prefix):
    """Remove apps entries and exceptions of '<vendor>/<app>' (or every app of '<vendor>/') from the security
    policy ConfigMaps (cicd-security-policy in the CI namespaces)."""
    for ns in (ENV.get("JENKINS_NAMESPACE", "cicd-jenkins"), ENV.get("RUNNER_NAMESPACE", "cicd-runner")):
        out = subprocess.run(["kubectl", "-n", ns, "get", "configmap", "cicd-security-policy", "-o", "json"],
                             capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            continue
        cm = json.loads(out.stdout)
        pol = json.loads((cm.get("data") or {}).get("policy.json") or "{}")
        hit = (lambda k: k.startswith(prefix)) if prefix.endswith("/") else (lambda k: k == prefix)
        apps = {k: v for k, v in (pol.get("apps") or {}).items() if not hit(k)}
        excs = [e for e in pol.get("exceptions") or [] if not hit(e.get("app", ""))]
        removed = len(pol.get("apps") or {}) - len(apps) + len(pol.get("exceptions") or []) - len(excs)
        if not removed:
            continue
        pol["apps"], pol["exceptions"] = apps, excs
        cm["data"]["policy.json"] = json.dumps(pol, ensure_ascii=False, indent=1)
        ann = cm["metadata"].setdefault("annotations", {})
        ann.update({"cicd.k-paas.org/updated-by": "cicd-portal", "cicd.k-paas.org/change": f"{prefix} 삭제"})
        rep = subprocess.run(["kubectl", "replace", "-f", "-"], input=json.dumps(cm), capture_output=True,
                             text=True, timeout=60)
        if rep.returncode != 0:
            raise SystemExit(f"[ERROR] {ns}/cicd-security-policy: {rep.stderr.strip()[:300]}")
        log(f"[OK]   security policy {ns}: {removed} entries of {prefix} removed")


def scm_app_repo(repo, description, ci_user, writers, owner):
    """Application repository: SCM-Manager (git, Jenkins) + cp_scm (scm.<domain> list and 참여자).
    Users without an scm.<domain> account yet (first login) get their permission on a later run."""
    scm = SCM()
    scm_users = scm.users()
    wanted = {w: "WRITE" for w in writers}
    if ci_user:
        wanted[ci_user] = "READ"
    ready = {u: lv for u, lv in wanted.items() if u in scm_users}
    scm_repo = scm.ensure_app_repo(repo, description, ready)
    registered, pending_db = ScmDB().register(scm_repo, scm.repositories(), description, owner, ready)
    pending = sorted(set(wanted) - set(ready) | set(pending_db))
    for user in pending:
        log(f"[WARN] {user} has not signed in to scm.<domain> yet - run 앱 추가 again after the first login "
            "to add the permission")
    print(json.dumps({"repo": repo, "registered": registered, "pending": pending}))


# ------------------------------------------------------------------ Jenkins ---
class Jenkins:
    # Folder permissions for the vendor group (matrix-auth): view, build, cancel, read logs
    VENDOR_PERMISSIONS = ["hudson.model.Item.Read", "hudson.model.Item.Discover", "hudson.model.Item.Build",
                          "hudson.model.Item.Cancel", "hudson.model.Item.Workspace", "hudson.model.Run.Replay"]

    def __init__(self):
        self.base = ENV["JENKINS_URL"].rstrip("/")
        cred = base64.b64encode(f"{ENV['JENKINS_USER']}:{ENV['JENKINS_API_TOKEN']}".encode()).decode()
        self.headers = {"Authorization": "Basic " + cred}

    def exists(self, path):
        try:
            request("GET", f"{self.base}{path}/api/json", self.headers)
            return True
        except HTTPError as e:
            if e.code == 404:
                return False
            raise

    def post_xml(self, path, xml):
        request("POST", self.base + path, self.headers, xml=xml)

    def ensure_folder(self, name, group):
        if self.exists(f"/job/{q(name)}"):
            log(f"[INFO] Jenkins folder exists: {name}")
            return
        perms = "\n".join(f"      <permission>GROUP:{p}:{xml_escape(group)}</permission>"
                          for p in self.VENDOR_PERMISSIONS)
        self.post_xml(f"/createItem?name={q(name)}", f"""<?xml version='1.1' encoding='UTF-8'?>
<com.cloudbees.hudson.plugins.folder.Folder>
  <description>{xml_escape(name)} services (CI/CD portal). Access: Keycloak group {xml_escape(group)}</description>
  <properties>
    <com.cloudbees.hudson.plugins.folder.properties.AuthorizationMatrixProperty>
      <inheritanceStrategy class="org.jenkinsci.plugins.matrixauth.inheritance.InheritParentStrategy"/>
{perms}
    </com.cloudbees.hudson.plugins.folder.properties.AuthorizationMatrixProperty>
  </properties>
</com.cloudbees.hudson.plugins.folder.Folder>""")
        log(f"[OK]   Jenkins folder {name} (group {group}: read/build)")

    def put_credential(self, folder, cid, username, password, description):
        store = f"/job/{q(folder)}/credentials/store/folder/domain/_"
        xml = f"""<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>{xml_escape(cid)}</id>
  <description>{xml_escape(description)}</description>
  <username>{xml_escape(username)}</username>
  <password>{xml_escape(password)}</password>
</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>"""
        if self.exists(f"{store}/credential/{q(cid)}"):
            self.post_xml(f"{store}/credential/{q(cid)}/config.xml", xml)
            log(f"[OK]   Jenkins credential updated: {folder}/{cid}")
        else:
            self.post_xml(f"{store}/createCredentials", xml)
            log(f"[OK]   Jenkins credential created: {folder}/{cid}")

    @staticmethod
    def job_xml(description, repo_url, credentials_id, release):
        if release:
            branch, lightweight, extra = "refs/tags/${RELEASE_TAG}", "false", """
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>RELEASE_TAG</name>
          <description>Release tag to build and deploy to prod, e.g. v1.2.0</description>
          <defaultValue></defaultValue>
          <trim>true</trim>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>"""
        else:
            branch, lightweight, extra = "*/develop", "true", """
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <hudson.triggers.SCMTrigger>
          <spec>H/5 * * * *</spec>
          <ignorePostCommitHooks>false</ignorePostCommitHooks>
        </hudson.triggers.SCMTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>"""
        return f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition>
  <description>{xml_escape(description)}</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty/>
    <jenkins.model.BuildDiscarderProperty>
      <strategy class="hudson.tasks.LogRotator">
        <daysToKeep>-1</daysToKeep>
        <numToKeep>30</numToKeep>
        <artifactDaysToKeep>-1</artifactDaysToKeep>
        <artifactNumToKeep>-1</artifactNumToKeep>
      </strategy>
    </jenkins.model.BuildDiscarderProperty>{extra}
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition">
    <scm class="hudson.plugins.git.GitSCM">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>{xml_escape(repo_url)}</url>
          <credentialsId>{xml_escape(credentials_id)}</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>{branch}</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>{lightweight}</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>"""

    @staticmethod
    def deploy_job_xml(description, script):
        """Image deploy job (application type image): the pipeline is stored in the job by the portal,
        so vendors cannot change it; parameters are filled by the CI/CD console."""
        params = "".join(f"""
        <hudson.model.StringParameterDefinition>
          <name>{n}</name>
          <description>{xml_escape(d)}</description>
          <defaultValue></defaultValue>
          <trim>true</trim>
        </hudson.model.StringParameterDefinition>""" for n, d in (
            ("IMAGE_TAG", "Image tag in Harbor (prod: vX.Y.Z)"),
            ("IMAGE_DIGEST", "sha256 digest of the tag (resolved by the CI/CD console)")))
        return f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition>
  <description>{xml_escape(description)}</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty/>
    <jenkins.model.BuildDiscarderProperty>
      <strategy class="hudson.tasks.LogRotator">
        <daysToKeep>-1</daysToKeep>
        <numToKeep>50</numToKeep>
        <artifactDaysToKeep>-1</artifactDaysToKeep>
        <artifactNumToKeep>-1</artifactNumToKeep>
      </strategy>
    </jenkins.model.BuildDiscarderProperty>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>{params}
        <hudson.model.ChoiceParameterDefinition>
          <name>TARGET</name>
          <description>dev, or prod (promotion of an image already deployed to dev)</description>
          <choices class="java.util.Arrays$ArrayList"><a class="string-array"><string>dev</string><string>prod</string></a></choices>
        </hudson.model.ChoiceParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition">
    <script>{xml_escape(script)}</script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>"""

    def put_job(self, folder, name, xml):
        path = f"/job/{q(folder)}/job/{q(name)}"
        if self.exists(path):
            self.post_xml(f"{path}/config.xml", xml)
            log(f"[OK]   Jenkins job updated: {folder}/{name}")
        else:
            self.post_xml(f"/job/{q(folder)}/createItem?name={q(name)}", xml)
            log(f"[OK]   Jenkins job created: {folder}/{name}")


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
    p = sub.add_parser("kc-user"); p.add_argument("username"); p.add_argument("--email", required=True)
    p = sub.add_parser("gl-wait"); p.add_argument("--timeout", type=int, default=900)
    sub.add_parser("gl-settings")
    p = sub.add_parser("gl-instance-var"); p.add_argument("pairs", nargs="+")
    p = sub.add_parser("gl-instance-secret"); p.add_argument("key")
    p = sub.add_parser("gl-group"); p.add_argument("path"); p.add_argument("--visibility", default="private")
    p = sub.add_parser("gl-project"); p.add_argument("namespace"); p.add_argument("path")
    p.add_argument("--visibility", default="private"); p.add_argument("--empty", action="store_true")
    p = sub.add_parser("gl-default-branch"); p.add_argument("project"); p.add_argument("branch")
    p = sub.add_parser("gl-push-dir"); p.add_argument("project"); p.add_argument("src")
    p.add_argument("--branch", default="main"); p.add_argument("--prefix", default="")
    p.add_argument("--subst", action="append", default=[]); p.add_argument("--message", default="Update by cicd-portal")
    p.add_argument("--only-missing", action="store_true"); p.add_argument("--exclude", action="append", default=[])
    p = sub.add_parser("gl-branch"); p.add_argument("project"); p.add_argument("branch"); p.add_argument("--ref", default="main")
    p = sub.add_parser("gl-protect-tag"); p.add_argument("project"); p.add_argument("pattern")
    p = sub.add_parser("gl-project-token"); p.add_argument("project"); p.add_argument("name")
    p.add_argument("--scopes", required=True); p.add_argument("--level", type=int, required=True)
    p = sub.add_parser("gl-group-var"); p.add_argument("group"); p.add_argument("key"); p.add_argument("--masked", action="store_true")
    p = sub.add_parser("gl-members"); p.add_argument("group"); p.add_argument("users"); p.add_argument("--level", type=int, default=30)
    p = sub.add_parser("gl-runner"); p.add_argument("description")
    p = sub.add_parser("gl-runners-online"); p.add_argument("description")
    p = sub.add_parser("scm-check"); p.add_argument("repo"); p.add_argument("--user", default="")
    p.add_argument("--level", default="READ", choices=["READ", "WRITE", "OWNER"])
    sub.add_parser("scm-ping")
    p = sub.add_parser("scm-app-repo"); p.add_argument("repo"); p.add_argument("--description", default="")
    p.add_argument("--ci-user", default=""); p.add_argument("--writers", default="")
    p.add_argument("--writers-group", default="", help="Keycloak group whose members get WRITE")
    p.add_argument("--owner", default="")
    p = sub.add_parser("scm-create"); p.add_argument("repo"); p.add_argument("--user", default="")
    p.add_argument("--level", default="WRITE", choices=["READ", "WRITE", "OWNER"]); p.add_argument("--description", default="")
    p = sub.add_parser("jenkins-folder"); p.add_argument("name"); p.add_argument("--group", required=True)
    p = sub.add_parser("jenkins-cred"); p.add_argument("folder"); p.add_argument("id")
    p.add_argument("--username", required=True); p.add_argument("--description", default="")
    p = sub.add_parser("jenkins-job"); p.add_argument("folder"); p.add_argument("name")
    p.add_argument("--repo-url", required=True); p.add_argument("--credentials", required=True)
    p.add_argument("--release", action="store_true"); p.add_argument("--description", default="")
    p = sub.add_parser("jenkins-deploy-job"); p.add_argument("folder"); p.add_argument("name")
    p.add_argument("--script-file", required=True); p.add_argument("--description", default="")
    p = sub.add_parser("harbor-immutable"); p.add_argument("project"); p.add_argument("--pattern", default="v*")
    p = sub.add_parser("harbor-delete-repo"); p.add_argument("project"); p.add_argument("repo")
    p = sub.add_parser("harbor-delete-project"); p.add_argument("project")
    p = sub.add_parser("harbor-robots"); p.add_argument("project"); p.add_argument("state", choices=["enable", "disable"])
    p = sub.add_parser("jenkins-delete"); p.add_argument("folder"); p.add_argument("name", nargs="?", default="")
    p = sub.add_parser("jenkins-jobs"); p.add_argument("folder"); p.add_argument("state", choices=["enable", "disable"])
    p.add_argument("--only", default="", help="comma separated job names (default: every job of the folder)")
    p = sub.add_parser("scm-delete-repo"); p.add_argument("repo", nargs="+")
    p.add_argument("--restart", action="store_true", help="restart SCM-Manager once if files are in use")
    p = sub.add_parser("scm-repos")
    p = sub.add_parser("scm-permissions")
    p = sub.add_parser("kc-group-members"); p.add_argument("name")
    p = sub.add_parser("scm-vendor-repos"); p.add_argument("vendor"); p.add_argument("--protect", default="")
    p = sub.add_parser("vendor-accounts"); p.add_argument("vendor"); p.add_argument("--ci-user", default="")
    p.add_argument("--extra", default=""); p.add_argument("--yes", action="store_true")
    p = sub.add_parser("kc-delete-group"); p.add_argument("name")
    p = sub.add_parser("gl-delete"); p.add_argument("path"); p.add_argument("--group", action="store_true")
    p = sub.add_parser("policy-forget"); p.add_argument("prefix")
    p = sub.add_parser("harbor-tag-digest"); p.add_argument("project"); p.add_argument("repo"); p.add_argument("tag")
    p = sub.add_parser("harbor-authfile"); p.add_argument("project"); p.add_argument("name")
    p.add_argument("--file", required=True)
    p = sub.add_parser("jenkins-trigger"); p.add_argument("folder"); p.add_argument("name")
    p.add_argument("params", nargs="*", help="KEY=VALUE")
    p = sub.add_parser("jenkins-ping")
    p = sub.add_parser("jenkins-build"); p.add_argument("folder"); p.add_argument("name")
    p = sub.add_parser("jenkins-disable"); p.add_argument("folder"); p.add_argument("name")
    p = sub.add_parser("harbor-project"); p.add_argument("name"); p.add_argument("--public", action="store_true")
    p = sub.add_parser("harbor-robot"); p.add_argument("project"); p.add_argument("name")
    p = sub.add_parser("harbor-security"); p.add_argument("project")
    p.add_argument("--prevent", default="", choices=["", "negligible", "low", "medium", "high", "critical"])
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
        elif a.cmd == "kc-user":
            created = Keycloak().ensure_user(a.username, a.email, sys.stdin.read().rstrip("\n"))
            print("created" if created else "exists")
        elif a.cmd == "gl-wait":
            print(GitLab().wait(a.timeout))
        elif a.cmd == "gl-settings":
            GitLab().call("PUT", "/application/settings?signup_enabled=false")
        elif a.cmd == "gl-instance-var":
            gl = GitLab()
            for pair in a.pairs:
                k, v = pair.split("=", 1)
                if not v:   # empty (e.g. CICD_NEXUS_URL not used): no variable, the templates fall back
                    if gl.get(f"/admin/ci/variables/{q(k)}") is not None:
                        gl.call("DELETE", f"/admin/ci/variables/{q(k)}")
                        log(f"[OK]   instance CI variable {k} removed")
                    continue
                gl.set_variable("/admin/ci", k, v, False)
                log(f"[OK]   instance CI variable {k}")
        elif a.cmd == "gl-instance-secret":
            GitLab().set_variable("/admin/ci", a.key, sys.stdin.read().rstrip("\n"), True)
            log(f"[OK]   instance CI variable {a.key} (masked)")
        elif a.cmd == "gl-group":
            print(GitLab().ensure_group(a.path, a.visibility))
        elif a.cmd == "gl-project":
            project, created = GitLab().ensure_project(a.namespace, a.path, a.visibility, a.empty)
            print("created" if created else "exists")
        elif a.cmd == "gl-default-branch":
            gl = GitLab()
            gl.call("PUT", f"/projects/{gl.project(a.project)['id']}", {"default_branch": a.branch})
            log(f"[OK]   default branch of {a.project}: {a.branch}")
        elif a.cmd == "gl-push-dir":
            subs = dict(s.split("=", 1) for s in a.subst)
            GitLab().push_dir(a.project, a.branch, a.src, a.prefix, subs, a.message, a.only_missing, a.exclude)
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
        elif a.cmd == "scm-check":
            problem = SCM().check(a.repo, a.user, a.level)
            if problem:
                log(f"[FAIL] {problem}")
                sys.exit(3)
            log(f"[OK]   SCM repository {a.repo}" + (f" ({a.user}: {a.level})" if a.user else ""))
        elif a.cmd == "scm-create":
            print("created" if SCM().create(a.repo, a.user, a.level, a.description) else "exists")
        elif a.cmd == "scm-app-repo":
            writers = [u.strip().lower() for u in a.writers.split(",") if u.strip()]
            if a.writers_group:
                writers += Keycloak().group_members(a.writers_group)
            writers = sorted({w for w in writers if w and w != a.ci_user and ScmDB.NAME_RE.match(w)})
            scm_app_repo(a.repo, a.description, a.ci_user, writers, a.owner)
        elif a.cmd == "scm-ping":
            print(len(SCM().repositories()))
        elif a.cmd == "jenkins-folder":
            Jenkins().ensure_folder(a.name, a.group)
        elif a.cmd == "jenkins-cred":
            Jenkins().put_credential(a.folder, a.id, a.username, sys.stdin.read().rstrip("\n"), a.description)
        elif a.cmd == "jenkins-job":
            j = Jenkins()
            j.put_job(a.folder, a.name, j.job_xml(a.description, a.repo_url, a.credentials, a.release))
        elif a.cmd == "jenkins-deploy-job":
            j = Jenkins()
            with open(a.script_file, encoding="utf-8") as fh:
                j.put_job(a.folder, a.name, j.deploy_job_xml(a.description, fh.read()))
        elif a.cmd == "harbor-immutable":
            Harbor().immutable(a.project, a.pattern)
        elif a.cmd == "harbor-delete-repo":
            Harbor().delete_repository(a.project, a.repo)
        elif a.cmd == "harbor-delete-project":
            Harbor().delete_project(a.project)
        elif a.cmd == "harbor-robots":
            Harbor().robots_enabled(a.project, a.state == "enable")
        elif a.cmd == "jenkins-delete":
            j = Jenkins()
            path = f"/job/{q(a.folder)}" + (f"/job/{q(a.name)}" if a.name else "")
            if j.exists(path):
                request("POST", f"{j.base}{path}/doDelete", j.headers, form={})
                log(f"[OK]   Jenkins {'job' if a.name else 'folder'} deleted: {a.folder}{'/' + a.name if a.name else ''}")
            else:
                log(f"[INFO] Jenkins {'job' if a.name else 'folder'} not found: {a.folder}{'/' + a.name if a.name else ''}")
        elif a.cmd == "jenkins-jobs":
            j = Jenkins()
            if a.only:
                names = [n for n in a.only.split(",") if n]
            else:
                try:
                    names = [x["name"] for x in request("GET", f"{j.base}/job/{q(a.folder)}/api/json?tree=jobs[name]",
                                                        j.headers)[1].get("jobs") or []]
                except HTTPError as e:
                    if e.code != 404:
                        raise
                    names = []
            for name in names:
                if j.exists(f"/job/{q(a.folder)}/job/{q(name)}"):
                    request("POST", f"{j.base}/job/{q(a.folder)}/job/{q(name)}/{a.state}", j.headers, form={})
                    log(f"[OK]   Jenkins job {a.state}d: {a.folder}/{name}")
        elif a.cmd == "scm-delete-repo":
            if scm_delete_repos(a.repo, a.restart):
                sys.exit(3)
        elif a.cmd == "scm-repos":
            print("\n".join(sorted(r.get("name", "") for r in SCM().repositories() if r.get("name"))))
        elif a.cmd == "scm-permissions":
            # scm.<domain> 참여자: repository, user, permission (backup-before-reinstall.sh)
            for row in ScmDB().sql("SELECT r.REPO_NAME, p.USER_ID, p.PERMISSION FROM SC_REPOSITORY r "
                                   "JOIN REPO_PERMITION p ON p.REPO_NO = r.REPO_NO ORDER BY r.REPO_NAME, p.USER_ID"):
                print("\t".join(row))
        elif a.cmd == "kc-group-members":
            print(",".join(Keycloak().group_members(a.name)))
        elif a.cmd == "scm-vendor-repos":
            print("\n".join(scm_vendor_repos(a.vendor, set(filter(None, a.protect.split(","))))))
        elif a.cmd == "vendor-accounts":
            vendor_accounts(a.vendor, a.ci_user, [x for x in a.extra.split(",") if x.strip()], a.yes)
        elif a.cmd == "kc-delete-group":
            print(",".join(Keycloak().delete_group(a.name)))
        elif a.cmd == "gl-delete":
            gl = GitLab()
            kind = "groups" if a.group else "projects"
            if gl.get(f"/{kind}/{q(a.path)}") is None:
                log(f"[INFO] GitLab {kind[:-1]} not found: {a.path}")
            else:
                gl.call("DELETE", f"/{kind}/{q(a.path)}")
                log(f"[OK]   GitLab {kind[:-1]} deleted: {a.path}")
        elif a.cmd == "policy-forget":
            policy_forget(a.prefix)
        elif a.cmd == "harbor-tag-digest":
            print(Harbor().tag_digest(a.project, a.repo, a.tag))
        elif a.cmd == "harbor-authfile":
            # fresh robot secret straight into a container auth file (0600): never printed or passed as an argument
            name, secret = Harbor().robot(a.project, a.name)
            host = urllib.parse.urlparse(ENV["HARBOR_URL"]).netloc
            auth = base64.b64encode(f"{name}:{secret}".encode()).decode()
            fd = os.open(a.file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as fh:
                json.dump({"auths": {host: {"auth": auth}}}, fh)
            print(name)
        elif a.cmd == "jenkins-trigger":
            params = dict(p.split("=", 1) for p in a.params if "=" in p)
            j = Jenkins()
            request("POST", f"{j.base}/job/{q(a.folder)}/job/{q(a.name)}/buildWithParameters", j.headers,
                    form=params)
            log(f"[OK]   Jenkins build queued: {a.folder}/{a.name}")
        elif a.cmd == "jenkins-build":
            j = Jenkins()
            request("POST", f"{j.base}/job/{q(a.folder)}/job/{q(a.name)}/build", j.headers, form={})
            log(f"[OK]   Jenkins build queued: {a.folder}/{a.name}")
        elif a.cmd == "jenkins-disable":
            j = Jenkins()
            if j.exists(f"/job/{q(a.folder)}/job/{q(a.name)}"):
                request("POST", f"{j.base}/job/{q(a.folder)}/job/{q(a.name)}/disable", j.headers, form={})
                log(f"[OK]   Jenkins job disabled: {a.folder}/{a.name}")
            else:
                log(f"[INFO] Jenkins job not found: {a.folder}/{a.name}")
        elif a.cmd == "jenkins-ping":
            request("GET", Jenkins().base + "/api/json", Jenkins().headers)
            print("ok")
        elif a.cmd == "harbor-project":
            Harbor().ensure_project(a.name, a.public)
        elif a.cmd == "harbor-security":
            Harbor().security(a.project, a.prevent)
        elif a.cmd == "harbor-robot":
            name, secret = Harbor().robot(a.project, a.name)
            print(name)
            print(secret)
    except HTTPError as e:
        log(f"[ERROR] {e}")
        if e.code in (301, 302, 303) and "jenkins" in str(e):
            log("[ERROR] Jenkins redirected the API call to the login page: the API token was not accepted.\n"
                "        Apply allowTokenAccessWithoutOicSession (./deploy-cicd-portal.sh jenkins) or register a\n"
                "        new token (JENKINS_USER=.. JENKINS_API_TOKEN=.. ./deploy-cicd-portal.sh jenkins-token).")
        sys.exit(1)
    except (urllib.error.URLError, OSError) as e:  # DNS, connection, TLS (certificate) errors
        log(f"[ERROR] {getattr(e, 'reason', e)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
