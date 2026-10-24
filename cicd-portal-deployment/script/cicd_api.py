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
import ssl
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
                                     "credentials": [{"type": "password", "value": password, "temporary": False}]})
        log(f"[OK]   Keycloak user created: {username}")
        return True

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
    """Read-only use of the SCM-Manager 1.x REST API. Repositories and permissions are
    managed in scm.<domain> so that the K-PaaS source control DB stays consistent."""
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
    p = sub.add_parser("scm-create"); p.add_argument("repo"); p.add_argument("--user", default="")
    p.add_argument("--level", default="WRITE", choices=["READ", "WRITE", "OWNER"]); p.add_argument("--description", default="")
    p = sub.add_parser("jenkins-folder"); p.add_argument("name"); p.add_argument("--group", required=True)
    p = sub.add_parser("jenkins-cred"); p.add_argument("folder"); p.add_argument("id")
    p.add_argument("--username", required=True); p.add_argument("--description", default="")
    p = sub.add_parser("jenkins-job"); p.add_argument("folder"); p.add_argument("name")
    p.add_argument("--repo-url", required=True); p.add_argument("--credentials", required=True)
    p.add_argument("--release", action="store_true"); p.add_argument("--description", default="")
    p = sub.add_parser("jenkins-ping")
    p = sub.add_parser("jenkins-build"); p.add_argument("folder"); p.add_argument("name")
    p = sub.add_parser("jenkins-disable"); p.add_argument("folder"); p.add_argument("name")
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
                gl.set_variable("/admin/ci", k, v, False)
                log(f"[OK]   instance CI variable {k}")
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
        elif a.cmd == "scm-ping":
            print(len(SCM().repositories()))
        elif a.cmd == "jenkins-folder":
            Jenkins().ensure_folder(a.name, a.group)
        elif a.cmd == "jenkins-cred":
            Jenkins().put_credential(a.folder, a.id, a.username, sys.stdin.read().rstrip("\n"), a.description)
        elif a.cmd == "jenkins-job":
            j = Jenkins()
            j.put_job(a.folder, a.name, j.job_xml(a.description, a.repo_url, a.credentials, a.release))
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
        elif a.cmd == "harbor-robot":
            name, secret = Harbor().robot(a.project, a.name)
            print(name)
            print(secret)
    except HTTPError as e:
        log(f"[ERROR] {e}")
        sys.exit(1)
    except (urllib.error.URLError, OSError) as e:  # DNS, connection, TLS (certificate) errors
        log(f"[ERROR] {getattr(e, 'reason', e)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
