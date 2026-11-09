"""Vendor members -> SCM repository permissions (참여자): grant, pending until the first login, revoke."""
import os
import sys
import unittest
from unittest import mock

import test_console as t

from cicd_console import services

sys.path.insert(0, os.environ["CICD_SCRIPT_DIR"])
import cicd_api  # noqa: E402


def perm(name, level):
    return {"name": name, "type": level, "groupPermission": False}


class FakeDB:
    """cp_scm: saeoll-homepage (1) and saeoll-board (2) listed in scm.<domain>."""

    def __init__(self):
        self.statements = []
        self.perms = {("1", "admin"): "OWNER", ("1", "dev1"): "OWNER", ("2", "dev1"): "WRITE", ("2", "dev2"): "READ"}

    lit = staticmethod(cicd_api.ScmDB.lit)
    permission_values = cicd_api.ScmDB.permission_values

    def users(self):
        return {"admin", "dev1", "dev2", "jenkins-saeoll"}

    def sql(self, statement):
        self.statements.append(statement)
        if statement.startswith("SELECT REPO_NO, REPO_NAME FROM SC_REPOSITORY"):
            return [["1", "saeoll-homepage"], ["2", "saeoll-board"]]
        if statement.startswith("SELECT DISTINCT PERMISSION"):
            return [[v] for v in set(self.perms.values())]
        if statement.startswith("SELECT REPO_NO, USER_ID, PERMISSION"):
            return [[n, u, p] for (n, u), p in self.perms.items()]
        if statement.startswith(("INSERT", "UPDATE", "DELETE")):
            return []
        raise AssertionError(statement)


class SyncTest(unittest.TestCase):
    def setUp(self):
        self.repos = [
            {"id": "h", "name": "saeoll-homepage", "permissions": [perm("dev1", "OWNER"), perm("jenkins-saeoll", "READ")]},
            {"id": "b", "name": "saeoll-board", "permissions": [perm("dev2", "READ")]},
            {"id": "g", "name": "saeoll-gitops", "permissions": [perm("jenkins-saeoll", "WRITE")]},
            {"id": "x", "name": "saeoll-x-web", "permissions": []},          # vendor saeoll-x
            {"id": "a", "name": "acme-shop", "permissions": []},
        ]
        self.calls = []
        self.db = FakeDB()

        def request(method, url, headers=None, data=None):
            self.calls.append((method, url, data))
            if url.endswith("/repositories.json"):
                return 200, self.repos
            if url.endswith("/users.json"):
                return 200, [{"name": n} for n in ("scmadmin", "dev1", "dev2", "jenkins-saeoll")]
            return 200, None
        for target, value in (("request", request), ("log", lambda m: None), ("ScmDB", lambda: self.db)):
            p = mock.patch.object(cicd_api, target, value)
            p.start()
            self.addCleanup(p.stop)
        p = mock.patch.dict(os.environ, {"SCM_URL": "https://scm/scm", "SCM_ADMIN_USER": "scmadmin",
                                         "SCM_ADMIN_PASSWORD": "x", "DATABASE_USER_PASSWORD": "y"})
        p.start()
        self.addCleanup(p.stop)

    def puts(self):
        return {c[1].rsplit("/", 1)[1]: {p["name"]: p["type"] for p in c[2]["permissions"]}
                for c in self.calls if c[0] == "PUT"}

    def test_grant_write_and_pending(self):
        r = cicd_api.scm_member_sync("saeoll", ["dev2", "Dev3", "jenkins-saeoll"], "WRITE",
                                     keep=["jenkins-saeoll"], others=["saeoll", "saeoll-x", "acme"])
        self.assertEqual(r["dev2"]["state"], "ok")
        self.assertEqual(r["dev2"]["repos"], 2)
        self.assertEqual(r["dev3"]["state"], "pending")                    # never signed in to scm.<domain>
        self.assertNotIn("jenkins-saeoll", r)                               # CI account untouched
        self.assertEqual(self.puts(), {"h": {"dev1": "OWNER", "jenkins-saeoll": "READ", "dev2": "WRITE"},
                                       "b": {"dev2": "WRITE"}})             # not gitops, not saeoll-x, not acme
        sql = "\n".join(self.db.statements)
        self.assertIn("INSERT INTO REPO_PERMITION (REPO_NO, USER_ID, PERMISSION) VALUES (1, 'dev2', 'WRITE')", sql)
        self.assertIn("UPDATE REPO_PERMITION SET PERMISSION='WRITE' WHERE REPO_NO=2 AND USER_ID='dev2'", sql)
        self.assertNotIn("dev3", sql)

    def test_never_lowered(self):
        r = cicd_api.scm_member_sync("saeoll", ["dev1"], "READ", others=["saeoll-x"])
        self.assertEqual(r["dev1"]["repos"], 2)
        self.assertEqual(self.puts(), {"b": {"dev2": "READ", "dev1": "READ"}})   # OWNER on homepage kept
        self.assertFalse(any(s.startswith(("UPDATE", "INSERT")) for s in self.db.statements))

    def test_revoke_keeps_owner(self):
        r = cicd_api.scm_member_sync("saeoll", ["dev1", "dev2"], revoke=True, others=["saeoll-x"])
        self.assertEqual(r["dev1"]["owner"], ["saeoll-homepage"])
        self.assertEqual(self.puts(), {"b": {}})
        delete = [s for s in self.db.statements if s.startswith("DELETE")][0]
        self.assertIn("USER_ID IN ('dev1', 'dev2') AND PERMISSION <> 'OWNER'", delete)

    def test_apply_records_state(self):
        with mock.patch.object(cicd_api, "vendor_scm_state") as state:
            cicd_api.scm_member_apply("saeoll", ["dev3"], others=[])
            self.assertEqual(state.call_args.kwargs["update"]["dev3"]["state"], "pending")
            cicd_api.scm_member_apply("saeoll", ["dev3"], revoke=True, others=[])
            self.assertEqual(state.call_args.kwargs["remove"], ["dev3", "dev3"])


class ConsoleTest(t.ConsoleBase):
    def setUp(self):
        super().setUp()
        self.kc = mock.Mock()
        self.kc.call.side_effect = lambda m, path, data=None: [{"id": "u1", "username": "dev3"}] if m == "GET" else None
        self.kc.ensure_group.return_value = "g1"
        api = mock.Mock(Keycloak=lambda: self.kc)
        api.scm_member_apply.return_value = {"dev3": {"state": "pending", "repos": 0, "owner": [], "error": ""}}
        self.api = api
        for target, value in (("api", lambda: api),):
            p = mock.patch.object(services, target, value)
            p.start()
            self.addCleanup(p.stop)
        p = mock.patch.dict(os.environ, {"SCM_ADMIN_PASSWORD": "x"})
        p.start()
        self.addCleanup(p.stop)

    def test_add_member_pending(self):
        self.login("admin", ["cicd-admins"])
        r = self.post("/vendors/saeoll/members", {"action": "add", "username": "dev3", "level": "WRITE"})
        self.assertEqual(r.status_code, 302)
        args = self.api.scm_member_apply.call_args.args
        self.assertEqual(args[:5], ("saeoll", ["dev3"], "WRITE", False, ["jenkins-saeoll"]))
        body = self.client.get("/vendors/saeoll").get_data(as_text=True)
        self.assertIn("첫 로그인 후 콘솔이 자동으로 쓰기 권한", body)
        self.assertEqual(self.post("/vendors/saeoll/members", {"action": "add", "username": "dev3",
                                                               "level": "OWNER"}).status_code, 302)
        self.assertEqual(self.api.scm_member_apply.call_count, 1)          # bad level: nothing changed

    def test_remove_member_revokes(self):
        self.login("admin", ["cicd-admins"])
        self.api.scm_member_apply.return_value = {"dev3": {"state": "removed", "repos": 2,
                                                           "owner": ["saeoll-homepage"], "error": ""}}
        self.post("/vendors/saeoll/members", {"action": "remove", "username": "dev3"})
        self.assertTrue(self.api.scm_member_apply.call_args.args[3])
        body = self.client.get("/vendors/saeoll").get_data(as_text=True)
        self.assertIn("2개에서 권한을 회수", body)
        self.assertIn("saeoll-homepage", body)

    def test_scm_error_does_not_fail_member_add(self):
        self.login("admin", ["cicd-admins"])
        self.api.scm_member_apply.side_effect = SystemExit("[ERROR] cp_scm: denied")
        self.post("/vendors/saeoll/members", {"action": "add", "username": "dev3"})
        body = self.client.get("/vendors/saeoll").get_data(as_text=True)
        self.assertIn("구성원에 추가", body)
        self.assertIn("SCM 저장소 권한 처리 실패", body)
        self.assertEqual(self.api.vendor_scm_state.call_args.kwargs["update"]["dev3"]["state"], "partial")

    def test_status_column_and_button(self):
        self.login("admin", ["cicd-admins"])
        state = {"dev1": {"level": "WRITE", "state": "pending", "repos": 0, "error": ""}}
        with mock.patch.dict(t.VENDORS[0], {"scm_members": state}):
            body = self.client.get("/vendors/saeoll").get_data(as_text=True)
        self.assertIn("첫 로그인 대기", body)
        self.assertIn("SCM 권한 다시 적용", body)
        with mock.patch.dict(t.VENDORS[0], {"scm_members": {"dev1": {"level": "WRITE", "state": "ok", "repos": 3}}}):
            body = self.client.get("/vendors/saeoll").get_data(as_text=True)
        self.assertIn("저장소 3개", body)
        self.login("dev1", ["cicd-saeoll"])
        body = self.client.get("/vendors/saeoll").get_data(as_text=True)
        self.assertNotIn('value="scm-sync"', body)
        self.assertEqual(self.post("/vendors/saeoll/members", {"action": "scm-sync"}).status_code, 403)

    def test_reconcile(self):
        state = {"dev1": {"level": "READ", "state": "pending"}, "gone": {"state": "pending"}}
        with mock.patch.dict(t.VENDORS[0], {"scm_members": state}), \
                mock.patch.object(services, "scm_member", return_value=("ok", "done")) as one:
            report = services.scm_reconcile()
            self.assertEqual(report, {"saeoll": [("ok", "done")]})
            self.assertEqual(one.call_args.args[1:], ("dev1", True, "READ"))
            self.assertEqual(self.api.vendor_scm_state.call_args.kwargs["remove"], ["gone"])
            one.reset_mock()
            self.login("admin", ["cicd-admins"])
            self.post("/vendors/saeoll/members", {"action": "scm-sync"})       # 다시 적용: every member
            self.assertEqual([c.args[1] for c in one.call_args_list], ["dev1"])

    def test_gitlab_pending(self):
        gl = mock.Mock()
        gl.sync_member.return_value = False
        with mock.patch.object(services, "GitLab", return_value=gl):
            category, msg = services.scm_member(t.VENDORS[1], "dev3", True)
        self.assertEqual(category, "warn")
        self.assertEqual(self.api.vendor_scm_state.call_args.kwargs["update"]["dev3"]["state"], "pending")


if __name__ == "__main__":
    unittest.main()
