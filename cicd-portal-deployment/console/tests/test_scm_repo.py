"""SCM repository creation at 앱 추가: console form and cicd_api (SCM-Manager + cp_scm DB)."""
import os
import sys
import unittest
from unittest import mock

import test_console as t

from cicd_console import jobs

sys.path.insert(0, os.environ["CICD_SCRIPT_DIR"])
import cicd_api  # noqa: E402


class FormTest(t.ConsoleBase):
    def test_create_repo_option(self):
        self.login("admin", ["cicd-admins"])
        with mock.patch.object(jobs, "start", return_value=mock.Mock(id="9")) as start:
            self.post("/vendors/saeoll/apps/new", {"app": "board", "type": "php", "scm_create": "on",
                                                   "scm_writers": "dev9, dev8"})
            self.assertEqual(start.call_args.kwargs["env"], {"SCM_CREATE_REPO": "1", "SCM_WRITERS": "dev9,dev8"})
            self.post("/vendors/saeoll/apps/new", {"app": "board", "type": "php"})
            self.assertNotIn("SCM_CREATE_REPO", start.call_args.kwargs["env"])
        body = self.client.get("/vendors/saeoll/apps/new").get_data(as_text=True)
        self.assertIn('name="scm_create" checked', body)


class FakeDB(cicd_api.ScmDB):
    """cp_scm with one repository created in scm.<domain> (the template)."""

    def __init__(self):
        self.statements = []
        self.repos = [["a1b2", "standalone", "admin", "202611010951", "saeoll-homepage", "7"]]
        self.perms = {("7", "admin"): "OWNER", ("7", "jenkins-saeoll"): "WRITE", ("7", "dev1"): "WRITE"}

    def sql(self, statement):
        self.statements.append(statement)
        if statement.startswith("SELECT REPO_SCM_ID"):
            return [r[:5] for r in self.repos]
        if statement.startswith("SELECT REPO_NO FROM SC_REPOSITORY WHERE REPO_NAME="):
            name = statement.split("=", 1)[1].strip("'")
            return [[r[5]] for r in self.repos if r[4] == name]
        if statement.startswith("INSERT INTO SC_REPOSITORY"):
            vals = statement.split("VALUES (", 1)[1].rstrip(")").split(", ")
            self.repos.append([vals[0].strip("'"), vals[3].strip("'"), vals[4].strip("'"), vals[6].strip("'"),
                               vals[1].strip("'"), "8"])
            return []
        if statement.startswith("SELECT DISTINCT PERMISSION"):
            return [[v] for v in set(self.perms.values())]
        if statement.startswith("SELECT USER_ID FROM REPO_PERMITION"):
            no = statement.rsplit("=", 1)[1]
            return [[u] for (n, u) in self.perms if n == no]
        if statement.startswith("SELECT DISTINCT USER_ID FROM SC_INSTANCE_USER"):
            return [["dev1"], ["dev2"], ["jenkins-saeoll"], ["admin"]]
        if statement.startswith("INSERT INTO REPO_PERMITION"):
            vals = statement.split("VALUES (", 1)[1].rstrip(")").split(", ")
            self.perms[(vals[0], vals[1].strip("'"))] = vals[2].strip("'")
            return []
        raise AssertionError(statement)


class ScmDBTest(unittest.TestCase):
    def test_register_like_the_ui(self):
        db = FakeDB()
        scm_repos = [{"id": "a1b2", "name": "saeoll-homepage"}, {"id": "c3d4", "name": "saeoll-board"}]
        with mock.patch.object(cicd_api, "log"):
            registered, pending = db.register(scm_repos[1], scm_repos, "board", "",
                                              {"dev1": "WRITE", "dev3": "WRITE", "jenkins-saeoll": "READ"})
        self.assertTrue(registered)
        self.assertEqual(pending, ["dev3"])                       # not signed in to scm.<domain> yet
        new = db.repos[-1]
        self.assertEqual(new[:3], ["c3d4", "standalone", "admin"])     # SCM-Manager id, instance and owner of the template
        self.assertRegex(new[3], r"^\d{12}$")
        self.assertEqual(db.perms[("8", "dev1")], "WRITE")
        self.assertEqual(db.perms[("8", "jenkins-saeoll")], "READ")      # READ not in the DB yet: same naming
        self.assertEqual(db.perms[("8", "admin")], "OWNER")              # owner row like scm.<domain>
        with mock.patch.object(cicd_api, "log"):                  # second run: nothing inserted again
            db.register(scm_repos[1], scm_repos, "board", "", {"dev1": "WRITE"})
        self.assertEqual(sum(s.startswith("INSERT INTO SC_REPOSITORY") for s in db.statements), 1)

    def test_unknown_permission_values_skip_participants(self):
        db = FakeDB()
        db.perms = {("7", "admin"): "관리자"}
        with mock.patch.object(cicd_api, "log") as log:
            registered, _ = db.register({"id": "c3d4", "name": "saeoll-board"},
                                        [{"id": "a1b2", "name": "saeoll-homepage"}, {"id": "c3d4", "name": "saeoll-board"}],
                                        "", "", {"dev1": "WRITE"})
        self.assertTrue(registered)
        self.assertFalse(any(s.startswith("INSERT INTO REPO_PERMITION") for s in db.statements))
        self.assertIn("not SCM-Manager permission names", log.call_args[0][0])

    def test_unknown_layout_writes_nothing(self):
        db = FakeDB()
        db.repos[0][3] = "2026-11-01"                              # unexpected time format
        with mock.patch.object(cicd_api, "log") as log:
            self.assertEqual(db.register({"id": "c3d4", "name": "x"}, [{"id": "a1b2", "name": "saeoll-homepage"}],
                                         "", "", {}), (False, []))
        self.assertFalse(any(s.startswith("INSERT") for s in db.statements))
        self.assertIn("not recognised", log.call_args[0][0])

    def test_scm_permissions_merge(self):
        scm = cicd_api.SCM.__new__(cicd_api.SCM)
        scm.base, scm.headers = "https://scm/api/rest", {}
        repo = {"id": "c3d4", "name": "saeoll-board", "permissions": [
            {"name": "dev1", "type": "OWNER", "groupPermission": False},
            {"name": "jenkins-saeoll", "type": "READ", "groupPermission": False}]}
        calls = []
        with mock.patch.object(cicd_api, "request", side_effect=lambda m, u, h=None, d=None: (
                calls.append((m, u, d)) or (200, [repo] if m == "GET" else None))), \
                mock.patch.object(cicd_api, "log"):
            scm.ensure_app_repo("saeoll-board", "", {"dev1": "WRITE", "dev2": "WRITE", "jenkins-saeoll": "READ"})
        put = [c for c in calls if c[0] == "PUT"][0]
        self.assertEqual(put[1], "https://scm/api/rest/repositories/c3d4")
        self.assertEqual({p["name"]: p["type"] for p in put[2]["permissions"]},
                         {"dev1": "OWNER", "jenkins-saeoll": "READ", "dev2": "WRITE"})   # never lowered


if __name__ == "__main__":
    unittest.main()
