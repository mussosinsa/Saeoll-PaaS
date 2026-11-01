"""Developer accounts created from the 업체 등록 form (Keycloak, temporary passwords shown once)."""
import unittest
from unittest import mock

import test_console as t

from cicd_console import jobs, services


class AccountTest(t.ConsoleBase):
    FORM = {"vendor": "anbsoft", "source": "scm", "ns_mode": "single", "users": "olduser",
            "new_users": "user11, 홍길동, hong@anbsoft.kr\n\nUser12 , Kim Cheolsu , kim@anbsoft.kr\n"}

    def setUp(self):
        super().setUp()
        self.login("admin", ["cicd-admins"])
        self.started = []
        real_start = jobs.Job

        def fake_start(title, script, args, user, env=None, secrets=()):
            job = real_start(title, script, args, env or {}, user, secrets)
            jobs._jobs[job.id] = job
            self.started.append(job)
            return job
        p = mock.patch.object(jobs, "start", side_effect=fake_start)
        p.start()
        self.addCleanup(p.stop)

    def test_create_and_show_once(self):
        with mock.patch.object(services, "existing_accounts", return_value=([], [])), \
                mock.patch.object(services, "create_user", side_effect=lambda u, n, e: f"Pw-{u}!9") as create:
            r = self.post("/admin/vendors/new", self.FORM)
        self.assertEqual(r.status_code, 302)
        self.assertEqual([c.args for c in create.call_args_list],
                         [("user11", "홍길동", "hong@anbsoft.kr"), ("user12", "Kim Cheolsu", "kim@anbsoft.kr")])
        job = self.started[0]
        self.assertEqual(job.args, ["--source", "scm", "--namespace", "single", "anbsoft", "olduser,user11,user12"])
        self.assertNotIn("Pw-user11!9", " ".join(job.args) + str(job.env))
        page = self.client.get(r.location)
        self.assertIn("Pw-user11!9", page.get_data(as_text=True))
        self.assertEqual(page.headers["Cache-Control"], "no-store")
        self.assertNotIn("Pw-user11!9", self.client.get(r.location).get_data(as_text=True))   # only once

    def test_duplicate_id_is_an_error(self):
        with mock.patch.object(services, "existing_accounts", return_value=(["user11"], [])), \
                mock.patch.object(services, "create_user") as create:
            body = self.post("/admin/vendors/new", self.FORM).get_data(as_text=True)
        self.assertIn("Keycloak에 이미 있는 ID입니다: user11", body)
        create.assert_not_called()
        self.assertEqual(self.started, [])

    def test_form_errors(self):
        with mock.patch.object(services, "existing_accounts", return_value=([], [])) as exists:
            for text, msg in (("user11, 홍길동", "형식"), ("User!, a, b@c.kr", "ID는"), ("user11, a, bad", "이메일"),
                              ("olduser, a, a@b.kr", "두 번"), ("u1, a, a@b.kr\nu1, b, b@b.kr", "두 번")):
                body = self.post("/admin/vendors/new", dict(self.FORM, new_users=text)).get_data(as_text=True)
                self.assertIn(msg, body, text)
            exists.assert_not_called()
        self.assertEqual(self.started, [])

    def test_partial_failure_shows_created(self):
        def create(u, n, e):
            if u == "user12":
                raise services.BackendError("HTTP 409")
            return "Pw1!"
        with mock.patch.object(services, "existing_accounts", return_value=([], [])), \
                mock.patch.object(services, "create_user", side_effect=create):
            body = self.post("/admin/vendors/new", self.FORM).get_data(as_text=True)
        self.assertIn("user12 생성 실패", body)
        self.assertIn("Pw1!", body)
        self.assertEqual(self.started, [])

    def test_reset_password(self):
        with mock.patch.object(services, "reset_password", return_value="New-Pw1!") as reset:
            r = self.post("/vendors/saeoll/members", {"action": "reset", "username": "dev1"})
        reset.assert_called_once_with("saeoll", "dev1")
        self.assertIn("New-Pw1!", r.get_data(as_text=True))
        self.login("dev1", ["cicd-saeoll"])
        self.assertEqual(self.post("/vendors/saeoll/members", {"action": "reset", "username": "dev1"}).status_code, 403)


class AccountServiceTest(unittest.TestCase):
    def test_helpers(self):
        self.assertEqual(services.split_name("홍길동"), ("길동", "홍"))
        self.assertEqual(services.split_name("Kim Cheolsu"), ("Kim", "Cheolsu"))
        for _ in range(20):
            p = services.temp_password()
            self.assertEqual(len(p), 14)
            self.assertTrue(any(c.isdigit() for c in p) and any(c.isupper() for c in p)
                            and any(c.islower() for c in p) and any(c in "!@#%*-_" for c in p))

    def test_keycloak_calls(self):
        kc = mock.Mock()
        kc.call.side_effect = lambda m, path, data=None: (
            [{"username": "user11", "email": "x@y.kr"}] if "username=user11" in path or "email=x%40y.kr" in path else
            [{"username": "dev1", "id": "u-1"}] if "username=dev1" in path else [] if m == "GET" else None)
        with mock.patch.object(services, "api", return_value=mock.Mock(Keycloak=lambda: kc)):
            self.assertEqual(services.existing_accounts(["user11", "user12"], ["x@y.kr", "z@y.kr"]),
                             (["user11"], ["x@y.kr"]))
            pw = services.create_user("user12", "홍길동", "z@y.kr")
            body = kc.call.call_args[0][2]
            self.assertEqual((body["firstName"], body["lastName"], body["credentials"][0]["temporary"],
                              body["credentials"][0]["value"]), ("길동", "홍", True, pw))
            with mock.patch.object(services, "members", return_value=[("dev1", "", "")]):
                pw = services.reset_password("saeoll", "dev1")
                self.assertEqual(kc.call.call_args[0][:2], ("PUT", "/users/u-1/reset-password"))
                with self.assertRaises(services.BackendError):
                    services.reset_password("saeoll", "admin")


if __name__ == "__main__":
    unittest.main()
