#!/usr/bin/env python3
"""Inspect a container image file uploaded to the CI/CD console (컨테이너 이미지 등록).

Accepted files (one image each):
  docker-archive : docker save / podman save            (manifest.json)
  oci-archive    : podman save --format oci-archive      (index.json; a multi-arch index uses linux/amd64)
  either one gzip-compressed (.tar.gz) - decompressed here next to the upload, the .gz is removed.

The archive is never extracted: only manifest.json / index.json and the image config are read, so file
names inside the tar cannot write anywhere. Prints JSON for upload-image.sh:
  {"path", "transport", "os", "arch", "user", "ports", "size", "warnings"}

Usage: image_archive.py prepare <file> [--max-bytes N]
"""
import argparse
import gzip
import json
import os
import shutil
import sys
import tarfile

JSON_LIMIT = 4 * 1024 * 1024      # manifest / index / config documents are small
INDEX_TYPES = {"application/vnd.oci.image.index.v1+json",
               "application/vnd.docker.distribution.manifest.list.v2+json"}


class ImageError(Exception):
    """The file is not a usable image archive (message shown to the uploader)."""


def gunzip(path, max_bytes):
    """Decompress path (gzip) to path + '.tar' with a size cap; returns the new path, removes the .gz."""
    out = path + ".tar"
    written = 0
    try:
        with gzip.open(path, "rb") as src, open(out, "wb") as dst:
            while True:
                chunk = src.read(1024 * 1024)
                if not chunk:
                    break
                written += len(chunk)
                if max_bytes and written > max_bytes:
                    raise ImageError(f"압축을 푼 크기가 {max_bytes // (1024 * 1024)}MiB를 넘습니다.")
                dst.write(chunk)
    except (OSError, EOFError) as e:
        if os.path.exists(out):
            os.remove(out)
        raise ImageError(f"gzip 파일을 풀 수 없습니다: {e}") from None
    except ImageError:
        os.remove(out)
        raise
    os.remove(path)
    return out


def _read_json(tar, name):
    name = name[2:] if name.startswith("./") else name
    try:
        member = tar.getmember(name)
    except KeyError:
        try:
            member = tar.getmember("./" + name)
        except KeyError:
            raise ImageError(f"이미지 파일에 {name}이(가) 없습니다.") from None
    if not member.isfile() or member.size > JSON_LIMIT:
        raise ImageError(f"이미지 파일의 {name}이(가) 올바르지 않습니다.")
    try:
        return json.load(tar.extractfile(member))
    except ValueError:
        raise ImageError(f"이미지 파일의 {name}을(를) 읽을 수 없습니다.") from None


def _has(tar, name):
    names = tar.getnames()
    return name in names or "./" + name in names


def _blob(digest):
    algo, _, hexpart = str(digest).partition(":")
    if algo != "sha256" or len(hexpart) != 64 or not all(c in "0123456789abcdef" for c in hexpart):
        raise ImageError(f"지원하지 않는 digest입니다: {digest}")
    return f"blobs/sha256/{hexpart}"


def _oci_config(tar):
    """Config of the single (or linux/amd64) image of an OCI layout."""
    index = _read_json(tar, "index.json")
    for _ in range(3):   # index -> (nested index ->) manifest
        manifests = index.get("manifests") or []
        if not manifests:
            raise ImageError("index.json에 이미지가 없습니다.")
        if len(manifests) > 1:
            amd64 = [m for m in manifests if (m.get("platform") or {}).get("architecture") == "amd64"
                     and (m.get("platform") or {}).get("os", "linux") == "linux"]
            if not amd64:
                if not any(m.get("platform") for m in manifests):
                    raise ImageError("이미지가 여러 개 들어 있습니다. 이미지 1개만 저장해 올리세요.")
                arches = ", ".join(sorted({(m.get('platform') or {}).get('architecture', '?') for m in manifests}))
                raise ImageError(f"linux/amd64 이미지가 없습니다 ({arches}).")
            manifests = amd64[:1]
        desc = manifests[0]
        doc = _read_json(tar, _blob(desc.get("digest")))
        if desc.get("mediaType") in INDEX_TYPES or doc.get("mediaType") in INDEX_TYPES or "manifests" in doc:
            index = doc
            continue
        config = (doc.get("config") or {}).get("digest")
        if not config:
            raise ImageError("이미지 manifest에 config가 없습니다.")
        return _read_json(tar, _blob(config))
    raise ImageError("index.json이 너무 깊게 중첩되어 있습니다.")


def inspect(path):
    try:
        tar = tarfile.open(path, "r:")
    except (tarfile.TarError, OSError):
        raise ImageError("tar 이미지 파일이 아닙니다 (docker save / podman save 결과를 올리세요).") from None
    with tar:
        if _has(tar, "manifest.json"):
            transport = "docker-archive"
            manifest = _read_json(tar, "manifest.json")
            if not isinstance(manifest, list) or not manifest:
                raise ImageError("manifest.json에 이미지가 없습니다.")
            if len(manifest) > 1:
                raise ImageError(f"이미지가 {len(manifest)}개 들어 있습니다. 이미지 1개만 저장해 올리세요.")
            config = _read_json(tar, manifest[0].get("Config", ""))
        elif _has(tar, "index.json"):
            transport = "oci-archive"
            config = _oci_config(tar)
        else:
            raise ImageError("이미지 파일이 아닙니다 (manifest.json / index.json 없음).")
    cfg = config.get("config") or {}
    os_name, arch = config.get("os", ""), config.get("architecture", "")
    if os_name and os_name != "linux":
        raise ImageError(f"linux 이미지가 아닙니다 ({os_name}).")
    if arch and arch != "amd64":
        raise ImageError(f"amd64 이미지가 아닙니다 ({arch}). --platform linux/amd64로 빌드하세요.")
    user = str(cfg.get("User") or "")
    ports = sorted({int(p.split("/")[0]) for p in (cfg.get("ExposedPorts") or {})
                    if p.split("/")[0].isdigit() and not p.endswith("/udp")})
    warnings = []
    if user.split(":")[0] in ("", "0", "root"):
        warnings.append("root 사용자로 실행되는 이미지입니다 (반입 기준: root가 아닌 사용자, 예: USER 1000).")
    if not ports:
        warnings.append("이미지에 EXPOSE 포트가 없습니다. 앱의 컨테이너 포트를 확인하세요.")
    return {"path": path, "transport": transport, "os": os_name or "linux", "arch": arch or "amd64",
            "user": user, "ports": ports, "size": os.path.getsize(path), "warnings": warnings}


def prepare(path, max_bytes=0):
    with open(path, "rb") as fh:
        magic = fh.read(2)
    if magic == b"\x1f\x8b":
        free = shutil.disk_usage(os.path.dirname(os.path.abspath(path))).free
        path = gunzip(path, min(max_bytes, free) if max_bytes else free)
    return inspect(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("file")
    p.add_argument("--max-bytes", type=int, default=0, help="limit of the decompressed size (gzip)")
    a = ap.parse_args()
    try:
        print(json.dumps(prepare(a.file, a.max_bytes), ensure_ascii=False))
    except ImageError as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
