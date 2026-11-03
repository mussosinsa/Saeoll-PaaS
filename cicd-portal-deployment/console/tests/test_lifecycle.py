"""서비스 중지 / 재개, 앱 삭제, 업체 중지 / 재개 / 삭제 (app-state.sh, remove-app.sh, vendor-state.sh, remove-vendor.sh)."""
import os
import sys
import unittest
from unittest import mock

import test_console as t

from cicd_console import jobs, services

sys.path.insert(0, os.environ["CICD_SCRIPT_DIR"])
import cicd_api  # noqa: E402


def stopped(env):
    return dict(env, stopped=True, stopped_by="admin", stopped_reason="점검 작업", stopped_at=t.NOW)


class LifecycleTest(t.ConsoleBase):
    def setUp(self):
        super().setUp()
        self.start = mock.patch.object(jobs, "start", return_value=mock.Mock(id="7")).start()
        self.addCleanup(mock.patch.stopall)

    def use_apps(self, apps, vendors=None):
        fakes = {"applications": lambda v=None: [a for a in apps if v in (None, a["vendor"])],
                 "application": lambda v, a: next((x for x in apps if (x["vendor"], x["app"]) == (v, a)), None)}
        if vendors:
            fakes["vendor"] = lambda n: next((v for v in vendors if v["name"] == n), None)
            fakes["vendors"] = lambda: vendors
        for name, fake in fakes.items():
            mock.patch.object(services, name, side_effect=fake).start()

    def homepage(self, prod_stopped=False, dev_stopped=False):
        dev = t.env("saeoll-homepage-dev", health="Degraded")
        prod = t.env("saeoll-homepage-prod", tag="v1.0.0", auto=False)
        return {"vendor": "saeoll", "app": "homepage", "type": "php",
                "envs": {"dev": stopped(dev) if dev_stopped else dev, "prod": stopped(prod) if prod_stopped else prod}}

    # ---------------------------------------------------------------- 서비스 중지 ---
    def test_stopped_badge_and_dashboard(self):
        self.use_apps([self.homepage(dev_stopped=True)])
        self.login("admin", ["cicd-admins"])
        body = self.client.get("/").get_data(as_text=True)
        self.assertIn("중지됨", body)
        self.assertIn("중지 1", body)
        self.assertIn('<b>0</b><span>오류 환경', body)          # a stopped (Degraded) env is not an error
        body = self.client.get("/vendors/saeoll/apps/homepage").get_data(as_text=True)
        self.assertIn("서비스 재개", body)
        self.assertIn("점검 작업", body)
        self.assertIn("앱 삭제", body)

    def test_app_state(self):
        self.use_apps([self.homepage()])
        self.login("dev1", ["cicd-saeoll"])
        body = self.client.get("/vendors/saeoll/apps/homepage").get_data(as_text=True)
        self.assertIn('data-open="stop-dev-dialog"', body)
        self.assertNotIn('data-open="stop-prod-dialog"', body)   # prod: operators only
        self.assertNotIn("앱 삭제", body)
        self.post("/vendors/saeoll/apps/homepage/state", {"env": "dev", "action": "stop", "reason": "x"})
        self.start.assert_not_called()                           # reason too short
        self.post("/vendors/saeoll/apps/homepage/state", {"env": "dev", "action": "stop", "reason": "점검 작업 중",
                                                          "ci_disable": "on"})
        args, kwargs = self.start.call_args
        self.assertEqual((args[1], args[2]), ("app-state.sh", ["saeoll", "homepage", "dev", "stop"]))
        self.assertEqual((kwargs["env"]["CI"], kwargs["env"]["ACTOR"]), ("disable", "dev1"))
        self.assertEqual(self.post("/vendors/saeoll/apps/homepage/state",
                                   {"env": "prod", "action": "stop", "reason": "점검 작업 중"}).status_code, 403)
        self.login("admin", ["cicd-admins"])
        self.post("/vendors/saeoll/apps/homepage/state", {"env": "prod", "action": "start"})
        self.assertEqual(self.start.call_args.args[2], ["saeoll", "homepage", "prod", "start"])

    # ------------------------------------------------------------------ 앱 삭제 ---
    def test_app_delete(self):
        self.use_apps([self.homepage()])
        self.login("dev1", ["cicd-saeoll"])
        self.assertEqual(self.client.get("/vendors/saeoll/apps/homepage/delete").status_code, 403)
        self.login("admin", ["cicd-admins"])
        body = self.client.get("/vendors/saeoll/apps/homepage/delete").get_data(as_text=True)
        self.assertIn("prod가 실행 중입니다", body)
        r = self.post("/vendors/saeoll/apps/homepage/delete", {"confirm": "homepage", "reason": "서비스 종료"})
        self.assertIn("먼저 prod 서비스를 중지", r.get_data(as_text=True))
        self.post("/vendors/saeoll/apps/homepage/delete", {"preview": "1", "delete_data": "on"})   # preview: allowed
        self.assertEqual(self.start.call_args.args[2], ["--delete-data", "saeoll", "homepage"])
        self.start.reset_mock()

        self.use_apps([self.homepage(prod_stopped=True)])
        r = self.post("/vendors/saeoll/apps/homepage/delete", {"confirm": "homepag", "reason": "서비스 종료"})
        self.assertIn("정확히 입력", r.get_data(as_text=True))
        self.start.assert_not_called()
        self.post("/vendors/saeoll/apps/homepage/delete", {"confirm": "homepage", "reason": "서비스 종료",
                                                           "delete_images": "on", "delete_repo": "on"})
        args, kwargs = self.start.call_args
        self.assertEqual((args[1], args[2]),
                         ("remove-app.sh", ["--yes", "--delete-images", "--delete-repo", "saeoll", "homepage"]))
        self.assertEqual(kwargs["env"]["REASON"], "서비스 종료")

    # --------------------------------------------------------------- 업체 중지 ---
    def test_vendor_suspend_and_read_only(self):
        self.login("admin", ["cicd-admins"])
        self.post("/vendors/saeoll/state", {"action": "suspend", "reason": "짧"})
        self.start.assert_not_called()
        self.post("/vendors/saeoll/state", {"action": "suspend", "reason": "유지보수 계약 종료"})
        self.assertEqual(self.start.call_args.args[1:3], ("vendor-state.sh", ["saeoll", "suspend"]))
        self.login("dev1", ["cicd-saeoll"])
        self.assertEqual(self.post("/vendors/saeoll/state", {"action": "resume"}).status_code, 403)

        vendors = [dict(t.VENDORS[0], suspended=True, suspended_by="admin", suspended_at=t.NOW,
                        suspended_reason="계약 종료"), t.VENDORS[1]]
        self.use_apps([self.homepage()], vendors)
        body = self.client.get("/vendors/saeoll").get_data(as_text=True)
        self.assertIn("업체가 중지되어 있습니다", body)
        r = self.post("/vendors/saeoll/apps/homepage/build")
        self.assertEqual(r.status_code, 403)                      # members: read only
        self.assertIn("중지되어", r.get_data(as_text=True))
        self.assertEqual(self.client.get("/vendors/saeoll/apps/homepage").status_code, 200)
        self.login("admin", ["cicd-admins"])
        self.assertIn("업체 재개", self.client.get("/vendors/saeoll").get_data(as_text=True))
        self.post("/vendors/saeoll/state", {"action": "resume"})
        self.assertEqual(self.start.call_args.args[2], ["saeoll", "resume"])

    # --------------------------------------------------------------- 업체 삭제 ---
    def test_vendor_delete(self):
        self.login("admin", ["cicd-admins"])
        self.use_apps([self.homepage()])
        body = self.client.get("/vendors/saeoll/delete").get_data(as_text=True)
        self.assertIn("prod가 실행 중인 앱", body)
        r = self.post("/vendors/saeoll/delete", {"confirm": "saeoll", "reason": "계약 종료", "with_apps": "on"})
        self.assertIn("먼저 업체를 중지", r.get_data(as_text=True))
        self.use_apps([self.homepage(prod_stopped=True)])
        r = self.post("/vendors/saeoll/delete", {"confirm": "saeoll", "reason": "계약 종료"})
        self.assertIn("앱이 남아 있습니다", r.get_data(as_text=True))
        self.start.assert_not_called()
        self.post("/vendors/saeoll/delete", {"confirm": "saeoll", "reason": "계약 종료", "with_apps": "on",
                                             "delete_data": "on"})
        self.assertEqual(self.start.call_args.args[1:3],
                         ("remove-vendor.sh", ["--yes", "--with-apps", "--delete-data", "saeoll"]))
        self.post("/vendors/saeoll/delete", {"confirm": "saeoll", "reason": "계약 종료", "with_apps": "on",
                                             "delete_repos": "on", "delete_users": "on", "users": "user11, user12",
                                             "scm_restart": "on"})
        args, kwargs = self.start.call_args
        self.assertEqual(args[2], ["--yes", "--with-apps", "--delete-repos", "--delete-users", "--users",
                                   "user11,user12", "saeoll"])
        self.assertEqual(kwargs["env"]["SCM_RESTART"], "1")
        self.start.reset_mock()
        r = self.post("/vendors/saeoll/delete", {"confirm": "saeoll", "reason": "계약 종료", "with_apps": "on",
                                                 "users": "user11"})
        self.assertIn("계정 삭제", r.get_data(as_text=True))          # extra users need 계정 삭제
        self.start.assert_not_called()
        self.login("dev1", ["cicd-saeoll"])
        self.assertEqual(self.client.get("/vendors/saeoll/delete").status_code, 403)

    def test_vendor_cleanup(self):
        self.login("admin", ["cicd-admins"])
        self.assertIn("남은 업체 정리", self.client.get("/admin/jobs").get_data(as_text=True))
        r = self.post("/admin/vendors/cleanup", {"vendor": "saeoll", "preview": "1"})
        self.assertIn("아직 등록되어", r.get_data(as_text=True))       # registered vendors: 업체 삭제
        self.post("/admin/vendors/cleanup", {"vendor": "soft", "preview": "1", "delete_repos": "on"})
        self.assertEqual(self.start.call_args.args[2], ["--delete-repos", "soft"])
        self.post("/admin/vendors/cleanup", {"vendor": "soft", "confirm": "soft", "reason": "삭제 중단 정리",
                                             "delete_repos": "on", "delete_users": "on", "scm_restart": "on"})
        self.assertEqual(self.start.call_args.args[2], ["--yes", "--delete-repos", "--delete-users", "soft"])
        self.login("dev1", ["cicd-saeoll"])
        self.assertEqual(self.client.get("/admin/vendors/cleanup").status_code, 403)


class VendorAccountsTest(unittest.TestCase):
    """cicd_api.vendor_accounts: which accounts 업체 삭제 (--delete-users) removes."""
    USERS = {"jenkins-soft": [], "dev1": ["cicd-soft"], "dev2": ["cicd-soft", "cicd-saeoll"],
             "boss": ["cicd-soft", "cicd-admins"], "admin": ["cicd-soft"], "old": []}

    def kc(self):
        kc = mock.Mock()
        kc.group_members.return_value = ["dev1", "dev2", "boss", "admin"]

        def call(method, path, data=None):
            if path.startswith("/users?username="):
                name = path.split("=")[1].split("&")[0]
                return [{"id": name, "username": name}] if name in self.USERS else []
            if path.endswith("/groups"):
                return [{"name": g} for g in self.USERS[path.split("/")[2]]]
            return None
        kc.call.side_effect = call
        return kc

    def test_selection(self):
        kc = self.kc()
        with mock.patch.object(cicd_api, "Keycloak", return_value=kc), mock.patch.object(cicd_api, "log"), \
                mock.patch.dict(os.environ, {"KEYCLOAK_ADMIN_GROUP": "cicd-admins"}):
            cicd_api.ENV.update(KEYCLOAK_ADMIN_GROUP="cicd-admins")
            chosen = cicd_api.vendor_accounts("soft", "jenkins-soft", ["old", "ghost"], False)
            self.assertEqual(sorted(chosen), ["dev1", "ghost", "jenkins-soft", "old"])   # dev2/boss/admin kept
            kept = cicd_api.vendor_accounts("soft", "user01", [], False)              # an existing CI account
            self.assertNotIn("user01", kept)
        self.assertFalse(any(c.args[0] == "DELETE" for c in kc.call.call_args_list))  # plan only

    def test_vendor_repos(self):
        scm = mock.Mock()
        scm.repositories.return_value = [{"name": n} for n in (
            "soft-gitops", "soft-node-board", "soft-vue-board", "soft-x-gitops", "soft-x-api", "saeoll", "software")]
        with mock.patch.object(cicd_api, "SCM", return_value=scm), mock.patch.dict(cicd_api.ENV, {"DATABASE_USER_PASSWORD": ""}):
            repos = cicd_api.scm_vendor_repos("soft", {"soft-x-gitops", "soft-x-"})
        self.assertEqual(repos, ["soft-gitops", "soft-node-board", "soft-vue-board"])


if __name__ == "__main__":
    unittest.main()
