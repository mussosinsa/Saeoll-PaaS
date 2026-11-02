"""Image applications: 앱 추가 (type image), 이미지 배포 / prod 승격, Harbor push account, Jenkins deploy builds."""
import datetime
import os
import sys
import unittest
from unittest import mock

import test_console as t

from cicd_console import jobs, services

sys.path.insert(0, os.environ["CICD_SCRIPT_DIR"])
import cicd_api  # noqa: E402

NOW = datetime.datetime.now(datetime.timezone.utc)
D1, D2 = "sha256:" + "a" * 64, "sha256:" + "b" * 64
IMAGES = [{"digest": D2, "tags": ["v1.1.0", "latest"], "pushed": NOW, "size": 1, "scan_status": "Success",
           "severity": "high", "critical": 0, "high": 2},
          {"digest": D1, "tags": ["dev-7"], "pushed": NOW, "size": 1, "scan_status": "Running", "severity": "",
           "critical": 0, "high": 0}]


class ImageAppTest(t.ConsoleBase):
    def setUp(self):
        super().setUp()
        image_app = {"vendor": "saeoll", "app": "erp", "type": "image",
                     "envs": {"dev": dict(t.env("saeoll-erp-dev"), digest=D2, tag="v1.1.0"),
                              "prod": t.env("saeoll-erp-prod", sync="OutOfSync", auto=False)}}
        for name, fake in {"application": lambda v, a: image_app if a == "erp" else None,
                           "applications": lambda v=None: [image_app]}.items():
            p = mock.patch.object(services, name, side_effect=fake)
            p.start()
            self.addCleanup(p.stop)
        harbor = mock.Mock()
        harbor.artifacts.return_value = IMAGES
        p = mock.patch.object(services, "Harbor", return_value=harbor)
        p.start()
        self.addCleanup(p.stop)

    def test_app_page(self):
        self.login("dev1", ["cicd-saeoll"])
        body = self.client.get("/vendors/saeoll/apps/erp").get_data(as_text=True)
        self.assertIn("이미지 배포", body)
        self.assertIn("prod 승격", body)
        self.assertIn("dev 배포 중", body)                     # the tag running in dev is marked
        promote = body[body.index('id="image-promote-dialog"'):]
        self.assertIn('value="v1.1.0"', promote)
        self.assertNotIn('value="dev-7"', promote)            # only vX.Y.Z can be promoted
        self.assertNotIn("빌드 실행", body)

    def test_deploy_and_promote(self):
        self.login("dev1", ["cicd-saeoll"])
        with mock.patch.object(services, "deploy_image", return_value=D1) as deploy:
            self.post("/vendors/saeoll/apps/erp/image-deploy", {"tag": "dev-7", "target": "dev"})
            deploy.assert_called_once()
            self.assertEqual(deploy.call_args.args[1:], ("erp", "dev-7", "dev"))
            self.post("/vendors/saeoll/apps/erp/image-deploy", {"tag": "dev-7", "target": "prod"})   # not vX.Y.Z
            self.post("/vendors/saeoll/apps/erp/image-deploy", {"tag": "bad tag!", "target": "dev"})
            self.assertEqual(deploy.call_count, 1)
            self.post("/vendors/saeoll/apps/erp/image-deploy", {"tag": "v1.1.0", "target": "prod"})
            self.assertEqual(deploy.call_args.args[1:], ("erp", "v1.1.0", "prod"))
        self.assertEqual(self.post("/vendors/saeoll/apps/homepage/image-deploy", {"tag": "v1"}).status_code, 404)

    def test_push_account(self):
        self.login("dev1", ["cicd-saeoll"])
        self.assertEqual(self.post("/vendors/saeoll/push-account").status_code, 403)
        self.login("admin", ["cicd-admins"])
        with mock.patch.object(services, "push_account", return_value=("robot$saeoll+push", "S3cret")):
            r = self.post("/vendors/saeoll/push-account")
        body = r.get_data(as_text=True)
        self.assertIn("S3cret", body)
        self.assertIn("robot$saeoll+push", body)
        self.assertEqual(r.headers["Cache-Control"], "no-store")

    def test_app_new_image(self):
        self.login("admin", ["cicd-admins"])
        with mock.patch.object(jobs, "start", return_value=mock.Mock(id="5")) as start:
            self.post("/vendors/saeoll/apps/new", {"app": "erp", "type": "image", "health": "tcp", "port": "3000",
                                                   "memory": "1Gi", "scm_create": "on"})
            args, kwargs = start.call_args
            self.assertEqual(args[2], ["saeoll", "erp", "image", "tcp"])
            self.assertEqual(kwargs["env"], {"APP_PORT": "3000", "APP_MEMORY_LIMIT": "1Gi"})   # no SCM repository
            body = self.post("/vendors/saeoll/apps/new", {"app": "erp", "type": "image", "port": "99999"}).get_data(as_text=True)
            self.assertIn("1~65535", body)
            self.assertEqual(start.call_count, 1)


class ServiceTest(unittest.TestCase):
    def test_deploy_builds_and_tags(self):
        data = {"builds": [{"number": 3, "result": "SUCCESS", "timestamp": 1700000000000,
                            "actions": [{"parameters": [{"name": "IMAGE_TAG", "value": "v1.1.0"},
                                                        {"name": "IMAGE_DIGEST", "value": D2},
                                                        {"name": "TARGET", "value": "prod"}]}]}]}
        with mock.patch.object(services, "cicd_secret", return_value="x"), \
                mock.patch.object(services, "http", return_value=(data, {})):
            b = services.Jenkins().builds("saeoll", "erp-deploy")[0]
        self.assertEqual((b["pipeline"], b["ref"], b["digest"]), ("release", "v1.1.0", D2))
        self.assertEqual(services._image_tag(f"harbor.x/saeoll/erp:v1.1.0@{D2}"), "v1.1.0")
        self.assertEqual(services._image_tag("harbor.x:443/saeoll/erp"), "")
        s = services.env_summary({"metadata": {"name": "x"}, "spec": {},
                                  "status": {"summary": {"images": [f"harbor.x/saeoll/erp:v1.1.0@{D2}"]}}})
        self.assertEqual((s["tag"], s["digest"]), ("v1.1.0", D2))

    def test_deploy_image_resolves_digest(self):
        jenkins, harbor = mock.Mock(), mock.Mock()
        harbor.digest.return_value = D1
        with mock.patch.object(services, "Jenkins", return_value=jenkins), \
                mock.patch.object(services, "Harbor", return_value=harbor):
            self.assertEqual(services.deploy_image({"name": "saeoll"}, "erp", "dev-7", "dev"), D1)
        jenkins.trigger.assert_called_once_with("saeoll", "erp-deploy",
                                                {"IMAGE_TAG": "dev-7", "IMAGE_DIGEST": D1, "TARGET": "dev"})

    def test_deploy_job_xml(self):
        import xml.dom.minidom
        with open(os.path.join(os.environ["CICD_SCRIPT_DIR"], "..", "starters", "image", "deploy.groovy"),
                  encoding="utf-8") as fh:
            script = fh.read()
        doc = xml.dom.minidom.parseString(cicd_api.Jenkins.deploy_job_xml("d", script))
        self.assertEqual([n.firstChild.data for n in doc.getElementsByTagName("name")],
                         ["IMAGE_TAG", "IMAGE_DIGEST", "TARGET"])
        self.assertEqual(doc.getElementsByTagName("sandbox")[0].firstChild.data, "true")
        self.assertIn("Promotion check", doc.getElementsByTagName("script")[0].firstChild.data)


if __name__ == "__main__":
    unittest.main()
