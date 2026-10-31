"""Tests of the CI/CD console with fake backends (no cluster needed).

  cd cicd-portal-deployment/console && python3 -m unittest discover -s tests -v
"""
import base64
import datetime
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

os.environ.update({
    "CICD_CONSOLE_CONFIG": "env", "HOST_DOMAIN": "10.0.0.1.nip.io", "CICD_SOURCES": "scm gitlab",
    "KEYCLOAK_ISSUER": "https://keycloak.10.0.0.1.nip.io/realms/cp-realm", "OIDC_CLIENT_ID": "cicd-console",
    "OIDC_CLIENT_SECRET": "s3cret", "CONSOLE_HOST": "cicd.10.0.0.1.nip.io", "ARGOCD_HOST": "argocd.10.0.0.1.nip.io",
    "JENKINS_HOST": "jenkins.10.0.0.1.nip.io", "JENKINS_URL": "https://jenkins.10.0.0.1.nip.io",
    "GITLAB_HOST": "gitlab.10.0.0.1.nip.io", "GITLAB_URL": "https://gitlab.10.0.0.1.nip.io",
    "HARBOR_URL": "https://harbor.10.0.0.1.nip.io", "CONSOLE_INSECURE_COOKIE": "1",
    "CICD_SCRIPT_DIR": str(HERE.parent.parent / "script"),
})

from cicd_console import auth, create_app, jobs, quality, services  # noqa: E402

NOW = datetime.datetime.now(datetime.timezone.utc)


def env(name, health="Healthy", sync="Synced", tag="dev-abc-1", auto=True):
    return {"name": name, "namespace": name.rsplit("-", 1)[0], "auto": auto, "sync": sync, "revision": "a" * 40,
            "health": health, "health_message": "", "images": [f"harbor/x/app:{tag}"], "tag": tag, "urls": [],
            "op_phase": "Succeeded", "op_message": "", "op_finished": NOW, "running": False,
            "history": [{"id": 2, "revision": "b" * 40, "deployed": NOW, "initiated_by": "admin"},
                        {"id": 1, "revision": "c" * 40, "deployed": NOW, "initiated_by": "admin"}],
            "resources": [{"kind": "Deployment", "name": "homepage", "status": "Synced", "health": health,
                           "message": ""}], "conditions": [], "reconciled": NOW}


VENDORS = [
    {"name": "saeoll", "source": "scm", "ns_mode": "split", "ci_user": "jenkins-saeoll",
     "namespaces": ["saeoll-dev", "saeoll-prod"], "repos": ["http://scm/git/saeoll-gitops"], "created": NOW},
    {"name": "acme", "source": "gitlab", "ns_mode": "single", "ci_user": "", "namespaces": ["acme"],
     "repos": ["http://gitlab/acme/gitops.git"], "created": NOW},
]
APPS = [
    {"vendor": "saeoll", "app": "homepage", "type": "php",
     "envs": {"dev": env("saeoll-homepage-dev"), "prod": env("saeoll-homepage-prod", sync="OutOfSync", tag="v1.0.0", auto=False)}},
    {"vendor": "acme", "app": "shop", "type": "node",
     "envs": {"dev": env("acme-shop-dev", health="Degraded"), "prod": env("acme-shop-prod", auto=False)}},
]
BUILDS = [{"id": "7", "number": 7, "job": "homepage-dev", "pipeline": "dev", "status": "running", "ref": "develop",
           "started": NOW, "duration": 0, "cause": "SCM change", "url": "https://jenkins/x/7/"},
          {"id": "3", "number": 3, "job": "homepage-release", "pipeline": "release", "status": "success",
           "ref": "v1.0.0", "started": NOW, "duration": 95, "cause": "admin", "url": "https://jenkins/y/3/"}]


class ConsoleBase(unittest.TestCase):
    """Console with fake backends (no tests of its own)."""
    def setUp(self):
        self.app = create_app()
        self.app.config["TESTING"] = True
        self.client = self.app.test_client()
        patches = {
            "vendors": lambda: VENDORS,
            "vendor": lambda n: next((v for v in VENDORS if v["name"] == n), None),
            "applications": lambda v=None: [a for a in APPS if v in (None, a["vendor"])],
            "application": lambda v, a: next((x for x in APPS if x["vendor"] == v and x["app"] == a), None),
            "builds": lambda v, a, limit=15: BUILDS,
            "release_tags": lambda v, a: ["v1.0.0"],
            "members": lambda v: [("dev1", "dev1@x", "Dev One")],
            "namespace_quota": lambda ns: [{"name": "pods", "used": "3", "hard": "30"}],
        }
        p = mock.patch.object(quality, "installed", return_value=False)   # 품질 관리: test_quality.py
        p.start()
        self.addCleanup(p.stop)
        for name, fake in patches.items():
            p = mock.patch.object(services, name, side_effect=fake)
            p.start()
            self.addCleanup(p.stop)

    def login(self, username, groups):
        with self.client.session_transaction() as s:
            s["user"] = {"username": username, "name": username, "groups": groups, "expires": time.time() + 600}
            s["csrf"] = "tok"

    def post(self, url, data=None):
        return self.client.post(url, data={"csrf_token": "tok", **(data or {})})


class ConsoleTest(ConsoleBase):

    # ---------------------------------------------------------------- auth ---
    def test_login_redirect(self):
        r = self.client.get("/vendors/saeoll")
        self.assertEqual(r.status_code, 302)
        self.assertIn("/login?next=/vendors/saeoll", r.location)
        r = self.client.get("/login?next=/vendors/saeoll")
        self.assertTrue(r.location.startswith(os.environ["KEYCLOAK_ISSUER"] + "/protocol/openid-connect/auth?"))
        self.assertIn("redirect_uri=https%3A%2F%2Fcicd.10.0.0.1.nip.io%2Foauth%2Fcallback", r.location)

    def test_callback(self):
        self.client.get("/login?next=/vendors/acme")
        with self.client.session_transaction() as s:
            state, nonce = s["oidc"]["state"], s["oidc"]["nonce"]
        claims = {"iss": os.environ["KEYCLOAK_ISSUER"], "aud": "cicd-console", "exp": time.time() + 60,
                  "nonce": nonce, "preferred_username": "dev1", "groups": ["/cicd-acme"]}
        token = "x." + base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=") + ".y"
        with mock.patch.object(services, "http", return_value=({"id_token": token}, {})):
            r = self.client.get(f"/oauth/callback?state={state}&code=abc")
        self.assertEqual(r.location, "/vendors/acme")
        with self.client.session_transaction() as s:
            self.assertEqual(s["user"]["groups"], ["cicd-acme"])
        r = self.client.get("/oauth/callback?state=wrong&code=abc")
        self.assertEqual(r.status_code, 400)

    def test_bad_nonce_rejected(self):
        self.client.get("/login")
        with self.client.session_transaction() as s:
            state = s["oidc"]["state"]
        claims = {"iss": os.environ["KEYCLOAK_ISSUER"], "aud": "cicd-console", "exp": time.time() + 60, "nonce": "x"}
        token = "x." + base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=") + ".y"
        with mock.patch.object(services, "http", return_value=({"id_token": token}, {})):
            self.assertEqual(self.client.get(f"/oauth/callback?state={state}&code=abc").status_code, 403)

    def test_csrf_required(self):
        self.login("admin", ["cicd-admins"])
        r = self.client.post("/vendors/saeoll/apps/homepage/build", data={})
        self.assertEqual(r.status_code, 400)

    # ---------------------------------------------------------- permissions ---
    def test_dashboard_admin_and_vendor(self):
        self.login("admin", ["cicd-admins"])
        body = self.client.get("/").get_data(as_text=True)
        self.assertIn("saeoll", body)
        self.assertIn("acme", body)
        self.assertIn("업체 등록", body)
        self.login("dev1", ["cicd-acme"])
        body = self.client.get("/").get_data(as_text=True)
        self.assertIn("shop", body)
        self.assertNotIn("homepage", body)
        self.assertNotIn("업체 등록", body)
        self.assertEqual(self.client.get("/vendors/saeoll").status_code, 403)
        self.assertEqual(self.client.get("/admin/vendors/new").status_code, 403)

    def test_no_group(self):
        self.login("nobody", ["other"])
        self.assertIn("접근할 수 있는 업체가 없습니다", self.client.get("/").get_data(as_text=True))

    def test_pages_render(self):
        self.login("admin", ["cicd-admins"])
        for url in ("/vendors/saeoll", "/vendors/acme", "/vendors/saeoll/apps/homepage", "/vendors/acme/apps/shop",
                    "/admin/vendors/new", "/vendors/saeoll/apps/new", "/vendors/saeoll/apps/homepage/db",
                    "/admin/jobs", "/vendors/saeoll/apps/homepage/builds/homepage-dev/7"):
            r = self.client.get(url)
            self.assertEqual(r.status_code, 200, url)
        body = self.client.get("/vendors/saeoll/apps/homepage").get_data(as_text=True)
        self.assertIn("prod Sync", body)
        self.assertIn("롤백", body)
        self.assertIn("data-autoreload", body)        # a build is running
        self.assertEqual(self.client.get("/vendors/nope").status_code, 404)
        self.assertEqual(self.client.get("/vendors/saeoll/apps/nope").status_code, 404)

    def test_sync_rules(self):
        self.login("dev1", ["cicd-saeoll"])
        with mock.patch.object(services, "sync") as sync:
            r = self.post("/vendors/saeoll/apps/homepage/sync", {"env": "dev"})
            self.assertEqual(r.status_code, 302)
            sync.assert_called_once_with("saeoll-homepage-dev", "dev1", None, "")
            self.assertEqual(self.post("/vendors/saeoll/apps/homepage/sync", {"env": "prod"}).status_code, 403)
        self.login("admin", ["cicd-admins"])
        with mock.patch.object(services, "sync") as sync:
            self.post("/vendors/saeoll/apps/homepage/sync", {"env": "prod", "revision": "c" * 40})
            sync.assert_called_once_with("saeoll-homepage-prod", "admin", "c" * 40, "")
            self.post("/vendors/saeoll/apps/homepage/sync", {"env": "dev", "revision": "c" * 40})
            self.assertEqual(sync.call_count, 1)        # no rollback of an auto-sync environment

    def test_release_rules(self):
        self.login("dev1", ["cicd-acme"])
        self.assertEqual(self.post("/vendors/acme/apps/shop/release", {"tag": "v1.0.0"}).status_code, 403)
        self.login("dev2", ["cicd-saeoll"])
        jenkins = mock.MagicMock()
        with mock.patch.object(services, "Jenkins", return_value=jenkins):
            self.post("/vendors/saeoll/apps/homepage/release", {"tag": "v1.2.0"})
            jenkins.trigger.assert_called_once_with("saeoll", "homepage-release", {"RELEASE_TAG": "v1.2.0"})
            self.post("/vendors/saeoll/apps/homepage/release", {"tag": "1.2"})
            self.assertEqual(jenkins.trigger.call_count, 1)

    def test_build_and_stop(self):
        self.login("dev1", ["cicd-acme"])
        gl = mock.MagicMock()
        with mock.patch.object(services, "GitLab", return_value=gl):
            self.post("/vendors/acme/apps/shop/build")
            gl.trigger.assert_called_once_with("acme/shop", "develop")
            self.post("/vendors/acme/apps/shop/stop", {"id": "55", "job": "acme/shop"})
            gl.cancel.assert_called_once_with("acme/shop", "55")

    def test_vendor_without_source(self):
        legacy = {"name": "user01", "source": "", "ns_mode": "split", "ci_user": "", "namespaces": ["user01-dev"],
                  "repos": [], "created": NOW}
        app = {"vendor": "user01", "app": "web", "type": "php", "envs": {"dev": env("user01-web-dev")}}
        self.login("admin", ["cicd-admins"])
        with mock.patch.object(services, "vendor", side_effect=lambda n: legacy), \
                mock.patch.object(services, "application", side_effect=lambda v, a: app), \
                mock.patch.object(services, "GitLab") as gl:
            self.assertIn("소스(scm|gitlab)가 기록되어 있지 않아",
                          self.client.get("/vendors/user01").get_data(as_text=True))
            r = self.post("/vendors/user01/apps/web/build")
            self.assertEqual(r.location, "/vendors/user01/apps/web")
            gl.assert_not_called()
        with self.assertRaises(services.BackendError):
            services.require_source(legacy)

    # -------------------------------------------------------------- scripts ---
    def test_onboard_form(self):
        self.login("admin", ["cicd-admins"])
        with mock.patch.object(jobs, "start", return_value=mock.Mock(id="1")) as start:
            r = self.post("/admin/vendors/new", {"vendor": "Bad Name", "source": "scm"})
            self.assertEqual(r.status_code, 200)
            start.assert_not_called()
            r = self.post("/admin/vendors/new", {"vendor": "newco", "source": "scm", "ns_mode": "split",
                                                 "users": "a, b", "scm_ci_password": "pw1"})
            self.assertEqual(r.location, "/admin/jobs/1")
            args, kwargs = start.call_args
            self.assertEqual(args[1:3], ("onboard-vendor.sh", ["--source", "scm", "--namespace", "split", "newco", "a,b"]))
            self.assertEqual(kwargs["env"]["SCM_CI_PASSWORD"], "pw1")
            self.assertIn("pw1", kwargs["secrets"])

    def test_add_app_and_db_forms(self):
        self.login("admin", ["cicd-admins"])
        with mock.patch.object(jobs, "start", return_value=mock.Mock(id="2")) as start:
            self.post("/vendors/saeoll/apps/new", {"app": "board", "type": "php", "db": "dedicated", "skip_starter": "on"})
            args, kwargs = start.call_args
            self.assertEqual(args[2], ["saeoll", "board", "php"])
            self.assertEqual(kwargs["env"], {"SKIP_STARTER": "1", "DB": "dedicated"})
            self.post("/vendors/saeoll/apps/homepage/db", {"env": "prod", "mode": "external", "db_host": "db",
                                                           "db_name": "n", "db_user": "u", "db_password": "p"})
            args, kwargs = start.call_args
            self.assertEqual(args[2], ["saeoll", "homepage", "prod", "external"])
            self.assertEqual(kwargs["env"]["DB_PASSWORD"], "p")

    def test_job_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            pathlib.Path(tmp, "demo.sh").write_text('echo "hello $1 $SECRET_VALUE"\necho oops >&2\nexit 3\n')
            with mock.patch.object(jobs.config, "SCRIPT_DIR", tmp):
                job = jobs.start("demo", "demo.sh", ["world"], "admin", env={"SECRET_VALUE": "hunter2"},
                                 secrets=["hunter2"])
                for _ in range(100):
                    if job.rc is not None:
                        break
                    time.sleep(0.05)
        self.assertEqual(job.lines, ["hello world ****", "oops"])
        self.assertEqual(job.status, "manual")
        self.assertEqual(job.env, {})
        self.login("admin", ["cicd-admins"])
        data = self.client.get(f"/api/jobs/{job.id}?offset=1").get_json()
        self.assertEqual(data["lines"], ["oops"])
        self.assertEqual(data["status"], "manual")


class ServicesTest(unittest.TestCase):
    def test_env_summary(self):
        obj = {"metadata": {"name": "saeoll-homepage-prod"},
               "spec": {"destination": {"namespace": "saeoll-prod"}, "syncPolicy": {}},
               "status": {"sync": {"status": "OutOfSync", "revision": "abc"}, "health": {"status": "Healthy"},
                          "summary": {"images": ["harbor.x/saeoll/homepage:v1.2.0"]},
                          "history": [{"id": 1, "revision": "r1", "deployedAt": "2026-10-01T00:00:00Z",
                                       "initiatedBy": {"automated": True}},
                                      {"id": 2, "revision": "r2", "deployedAt": "2026-10-02T00:00:00Z",
                                       "initiatedBy": {"username": "admin"}}]}}
        s = services.env_summary(obj)
        self.assertEqual((s["tag"], s["auto"], s["sync"]), ("v1.2.0", False, "OutOfSync"))
        self.assertEqual([h["id"] for h in s["history"]], [2, 1])
        self.assertEqual(s["history"][1]["initiated_by"], "자동 Sync")
        with mock.patch.dict(os.environ, {"HARBOR_HOST": "harbor.x"}):
            both = {"metadata": {"name": "x"}, "spec": {},
                    "status": {"summary": {"images": ["docker.io/library/mariadb:11.4", "harbor.x/saeoll/web:dev-1"]}}}
            self.assertEqual(services.env_summary(both)["tag"], "dev-1")
        self.assertEqual(services.env_summary({"metadata": {"name": "x"}, "spec": {"source": {}},
                                               "status": {"summary": {"images": ["harbor:443/a/b"]}}})["tag"], "")

    def test_sync_patch(self):
        obj = {"metadata": {"name": "a"}, "spec": {"source": {"targetRevision": "main"}}, "status": {}}
        with mock.patch.object(services, "get_json", return_value=obj), \
                mock.patch.object(services, "kubectl") as kubectl:
            services.sync("a", "admin", "r1")
            patch = json.loads(kubectl.call_args.kwargs["stdin"])
            self.assertEqual(patch["operation"]["sync"]["revision"], "r1")
            self.assertEqual(patch["operation"]["initiatedBy"]["username"], "admin (cicd-console)")
        busy = dict(obj, operation={})
        with mock.patch.object(services, "get_json", return_value=busy):
            with self.assertRaises(services.BackendError):
                services.sync("a", "admin")

    def test_jenkins_builds(self):
        data = {"builds": [{"number": 4, "building": False, "result": "FAILURE", "timestamp": 1700000000000,
                            "duration": 61000, "actions": [{"parameters": [{"name": "RELEASE_TAG", "value": "v2.0.0"}]},
                                                           {"causes": [{"shortDescription": "Started by admin"}]}]},
                           {"number": 5, "building": True, "result": None, "timestamp": 1700000100000}]}
        with mock.patch.object(services, "cicd_secret", side_effect=lambda k: "x"), \
                mock.patch.object(services, "http", return_value=(data, {})):
            builds = services.Jenkins().builds("saeoll", "homepage-release")
        self.assertEqual([b["status"] for b in builds], ["failed", "running"])
        self.assertEqual((builds[0]["ref"], builds[0]["pipeline"], builds[0]["duration"]), ("v2.0.0", "release", 61))
        self.assertEqual(builds[1]["ref"], "develop")

    def test_permissions_helpers(self):
        user = {"groups": ["cicd-acme", "cicd-saeoll", "other"]}
        self.assertEqual(auth.user_vendors(user), ["acme", "saeoll"])
        self.assertIsNone(auth.user_vendors({"groups": ["cicd-admins"]}))


if __name__ == "__main__":
    unittest.main()
