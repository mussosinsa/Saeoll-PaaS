"""컨테이너 이미지 등록: upload page, streamed upload -> upload-image.sh job, image_archive.py inspection."""
import gzip
import io
import json
import os
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

import test_console as t

from cicd_console import jobs, services

sys.path.insert(0, os.environ["CICD_SCRIPT_DIR"])
import image_archive  # noqa: E402

ERP = {"vendor": "saeoll", "app": "erp", "type": "image", "envs": {"dev": t.env("saeoll-erp-dev")}}


def _add(tar, name, data):
    if isinstance(data, (dict, list)):
        data = json.dumps(data).encode()
    info = tarfile.TarInfo(name)
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))


def docker_archive(path, arch="amd64", user="1000", images=1):
    config = {"os": "linux", "architecture": arch, "config": {"User": user, "ExposedPorts": {"3000/tcp": {}}}}
    with tarfile.open(path, "w") as tar:
        _add(tar, "cfg.json", config)
        _add(tar, "layer.tar", b"x" * 10)
        _add(tar, "manifest.json", [{"Config": "cfg.json", "RepoTags": ["x:1"], "Layers": ["layer.tar"]}] * images)


def oci_archive(path, arches=("amd64", "arm64")):
    blobs, index = {}, []
    for arch in arches:
        cfg = json.dumps({"os": "linux", "architecture": arch, "config": {}}).encode()
        cfg_d = "sha256:" + format(len(blobs), "064x")
        blobs[cfg_d] = cfg
        man = json.dumps({"schemaVersion": 2, "config": {"digest": cfg_d}, "layers": []}).encode()
        man_d = "sha256:" + format(len(blobs) + 100, "064x")
        blobs[man_d] = man
        index.append({"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": man_d,
                      "platform": {"os": "linux", "architecture": arch}})
    with tarfile.open(path, "w") as tar:
        _add(tar, "oci-layout", {"imageLayoutVersion": "1.0.0"})
        for d, data in blobs.items():
            _add(tar, "blobs/sha256/" + d.split(":")[1], data)
        _add(tar, "index.json", {"schemaVersion": 2, "manifests": index})


class ImageArchiveTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "img")

    def write(self, data):
        with open(self.path, "wb") as fh:
            fh.write(data)

    def test_docker_archive(self):
        docker_archive(self.path)
        info = image_archive.prepare(self.path)
        self.assertEqual((info["transport"], info["arch"], info["ports"], info["warnings"]),
                         ("docker-archive", "amd64", [3000], []))

    def test_gzip_and_root_warning(self):
        docker_archive(self.path + ".plain", user="")
        with open(self.path + ".plain", "rb") as src, gzip.open(self.path, "wb") as dst:
            dst.write(src.read())
        info = image_archive.prepare(self.path)
        self.assertEqual(info["path"], self.path + ".tar")
        self.assertFalse(os.path.exists(self.path))              # the .gz is replaced by the .tar
        self.assertIn("root", info["warnings"][0])
        with open(self.path + ".plain", "rb") as src, gzip.open(self.path, "wb") as dst:
            dst.write(src.read())
        with self.assertRaisesRegex(image_archive.ImageError, "MiB"):
            image_archive.prepare(self.path, max_bytes=100)

    def test_oci_multi_arch_picks_amd64(self):
        oci_archive(self.path)
        info = image_archive.prepare(self.path)
        self.assertEqual((info["transport"], info["arch"]), ("oci-archive", "amd64"))

    def test_refused(self):
        for build, message in ((lambda: docker_archive(self.path, arch="arm64"), "amd64"),
                               (lambda: docker_archive(self.path, images=2), "1개만"),
                               (lambda: oci_archive(self.path, arches=("arm64",)), "amd64"),
                               (lambda: self.write(b"not a tar" * 100), "tar")):
            build()
            with self.assertRaisesRegex(image_archive.ImageError, message):
                image_archive.prepare(self.path)


class ImageUploadTest(t.ConsoleBase):
    def setUp(self):
        super().setUp()
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        p = mock.patch.dict(os.environ, {"CICD_UPLOAD_DIR": self.dir.name, "CICD_UPLOAD_MAX_MB": "1"})
        p.start()
        self.addCleanup(p.stop)
        apps = t.APPS + [ERP]
        for name, fake in {"application": lambda v, a: next((x for x in apps if (x["vendor"], x["app"]) == (v, a)), None),
                           "applications": lambda v=None: [a for a in apps if v in (None, a["vendor"])]}.items():
            p = mock.patch.object(services, name, side_effect=fake)
            p.start()
            self.addCleanup(p.stop)
        self.start = mock.patch.object(jobs, "start", return_value=mock.Mock(id="9")).start()
        self.addCleanup(mock.patch.stopall)

    def upload(self, query, body=b"IMAGEDATA", csrf="tok"):
        return self.client.post(f"/vendors/saeoll/images/upload?{query}", data=body,
                                headers={"X-CSRF-Token": csrf, "Content-Type": "application/octet-stream"})

    def test_page_and_buttons(self):
        self.login("dev1", ["cicd-saeoll"])
        self.assertIn("컨테이너 이미지 등록", self.client.get("/vendors/saeoll").get_data(as_text=True))
        body = self.client.get("/vendors/saeoll/images/new?app=erp").get_data(as_text=True)
        self.assertIn('<option value="erp" selected>', body)
        self.assertNotIn('value="homepage"', body)                # only image apps
        self.assertNotIn("__new__", body)                         # new apps: operators only
        self.login("admin", ["cicd-admins"])
        self.assertIn("__new__", self.client.get("/vendors/saeoll/images/new").get_data(as_text=True))
        self.assertNotIn("컨테이너 이미지 등록", self.client.get("/vendors/acme").get_data(as_text=True))  # gitlab

    def test_upload_existing_app(self):
        self.login("dev1", ["cicd-saeoll"])
        r = self.upload("app=erp&tag=v1.2.0&deploy=1")
        self.assertEqual(r.status_code, 200, r.get_data(as_text=True))
        self.assertEqual(r.get_json()["job"], "/admin/jobs/9")
        args, kwargs = self.start.call_args
        self.assertEqual(args[1], "upload-image.sh")
        vendor, app, tag, path = args[2]
        self.assertEqual((vendor, app, tag), ("saeoll", "erp", "v1.2.0"))
        with open(path, "rb") as fh:
            self.assertEqual(fh.read(), b"IMAGEDATA")             # streamed to the upload directory
        self.assertTrue(path.startswith(self.dir.name))
        self.assertEqual(kwargs["env"]["DEPLOY_DEV"], "1")
        self.assertNotIn("NEW_APP", kwargs["env"])

    def test_upload_refused(self):
        self.login("dev1", ["cicd-saeoll"])
        cases = [("app=homepage&tag=v1", 400),                    # not an image app
                 ("app=erp&tag=bad tag", 400),
                 ("app=newapp&tag=v1&new=1", 403),                 # new app: operators only
                 ("app=erp&tag=v1", 413, b"x" * (1024 * 1024 + 1))]
        for query, status, *body in cases:
            r = self.upload(query, *body)
            self.assertEqual(r.status_code, status, query)
            self.assertIn("error", r.get_json())
        self.assertEqual(self.upload("app=erp&tag=v1", csrf="bad").status_code, 400)
        self.start.assert_not_called()
        self.assertEqual(os.listdir(self.dir.name), [])           # nothing left behind
        self.login("other", ["cicd-acme"])
        self.assertEqual(self.upload("app=erp&tag=v1").status_code, 403)

    def test_upload_new_app_admin(self):
        self.login("admin", ["cicd-admins"])
        self.assertEqual(self.upload("app=erp&tag=v1&new=1").status_code, 400)   # already exists
        r = self.upload("app=billing&tag=v1.0.0&new=1&health=tcp&port=3000&memory=1Gi&deploy=0")
        self.assertEqual(r.status_code, 200, r.get_data(as_text=True))
        env = self.start.call_args.kwargs["env"]
        self.assertEqual((env["NEW_APP"], env["APP_HEALTH"], env["APP_PORT"], env["APP_MEMORY_LIMIT"], env["DEPLOY_DEV"]),
                         ("1", "tcp", "3000", "1Gi", "0"))
        self.assertEqual(self.upload("app=billing2&tag=v1&new=1&port=99999").status_code, 400)
        self.assertEqual(self.upload("app=erp&tag=v2").status_code, 409)      # previous upload still waiting

    def test_job_page_for_its_user(self):
        job = mock.Mock(id="9", user="dev1", title="이미지 등록", command="./upload-image.sh", status="running",
                        created=t.NOW, lines=["[OK] pushed"], rc=None, credentials=None)
        with mock.patch.object(jobs, "get", return_value=job):
            self.login("dev1", ["cicd-saeoll"])
            self.assertEqual(self.client.get("/admin/jobs/9").status_code, 200)
            self.assertEqual(self.client.get("/api/jobs/9").get_json()["lines"], ["[OK] pushed"])
            self.login("dev2", ["cicd-saeoll"])
            self.assertEqual(self.client.get("/admin/jobs/9").status_code, 403)
            self.assertEqual(self.client.get("/admin/jobs").status_code, 403)


if __name__ == "__main__":
    unittest.main()
