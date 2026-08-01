#!/usr/bin/env python3
"""Idempotently upload one verified release with the official Mod Portal v2 API."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import NoReturn


PORTAL_ORIGIN = "https://mods.factorio.com"
INIT_UPLOAD_URL = f"{PORTAL_ORIGIN}/api/v2/mods/releases/init_upload"
USER_AGENT = "Sceatorio-release/1 (+https://github.com/Sceat/sceatorio)"


def fail(message: str) -> NoReturn:
    raise SystemExit(f"portal upload: {message}")


def request_json(request: urllib.request.Request, *, attempts: int = 3) -> dict:
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read()
                if response.status < 200 or response.status >= 300:
                    fail(f"HTTP {response.status}")
                value = json.loads(body)
                if not isinstance(value, dict):
                    fail("API returned a non-object response")
                return value
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")
            fail(f"HTTP {error.code}: {body[:500]}")
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            if attempt == attempts:
                fail(f"request failed after {attempts} attempts: {error}")
            time.sleep(attempt * 2)
    fail("unreachable request failure")


def archive_identity(path: Path) -> tuple[str, str, str]:
    digest = hashlib.sha1(path.read_bytes()).hexdigest()
    try:
        with zipfile.ZipFile(path) as bundle:
            candidates = [name for name in bundle.namelist() if name.count("/") == 1 and name.endswith("/info.json")]
            if len(candidates) != 1:
                fail("archive must contain exactly one root info.json")
            info = json.loads(bundle.read(candidates[0]))
    except (OSError, zipfile.BadZipFile, KeyError, json.JSONDecodeError) as error:
        fail(f"cannot inspect archive: {error}")
    name = info.get("name")
    version = info.get("version")
    expected_root = f"{name}_{version}"
    if candidates[0] != f"{expected_root}/info.json" or path.name != f"{expected_root}.zip":
        fail("archive filename, root, name, and version do not agree")
    return str(name), str(version), digest


def public_release(name: str, version: str) -> dict | None:
    url = f"{PORTAL_ORIGIN}/api/mods/{urllib.parse.quote(name, safe='')}/full"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    details = request_json(request)
    matches = [release for release in details.get("releases", []) if release.get("version") == version]
    if len(matches) > 1:
        fail(f"public API returned duplicate {version} releases")
    return matches[0] if matches else None


def multipart_file(field: str, path: Path) -> tuple[bytes, str]:
    boundary = f"sceatorio-{secrets.token_hex(24)}"
    safe_name = path.name.replace('"', "")
    prefix = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{field}"; filename="{safe_name}"\r\n'
        "Content-Type: application/zip\r\n\r\n"
    ).encode("ascii")
    suffix = f"\r\n--{boundary}--\r\n".encode("ascii")
    return prefix + path.read_bytes() + suffix, f"multipart/form-data; boundary={boundary}"


def upload(path: Path, name: str, api_key: str) -> None:
    body = urllib.parse.urlencode({"mod": name}).encode("ascii")
    init = request_json(
        urllib.request.Request(
            INIT_UPLOAD_URL,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": USER_AGENT,
            },
        ),
        attempts=1,
    )
    upload_url = init.get("upload_url")
    parsed = urllib.parse.urlparse(str(upload_url))
    if parsed.scheme != "https" or not parsed.netloc:
        fail("init_upload returned an unsafe upload URL")
    payload, content_type = multipart_file("file", path)
    result = request_json(
        urllib.request.Request(
            str(upload_url),
            data=payload,
            method="POST",
            headers={"Content-Type": content_type, "User-Agent": USER_AGENT},
        ),
        attempts=1,
    )
    if result.get("success") is not True:
        fail(f"upload was not acknowledged: {json.dumps(result, sort_keys=True)}")


def wait_for_release(name: str, version: str, sha1: str) -> None:
    for attempt in range(1, 13):
        release = public_release(name, version)
        if release:
            if release.get("sha1") != sha1:
                fail(f"portal release {version} exists with a different SHA-1")
            print(f"portal upload: verified {name} {version} ({sha1})")
            return
        time.sleep(min(attempt * 2, 15))
    fail("upload succeeded but the release did not appear in the public API")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument(
        "--api-key-env",
        default="FACTORIO_MOD_PORTAL_API_KEY",
        help="environment variable containing a ModPortal: Upload Mods key",
    )
    arguments = parser.parse_args()
    path = arguments.archive.resolve()
    if not path.is_file():
        fail(f"archive does not exist: {path}")
    name, version, sha1 = archive_identity(path)

    existing = public_release(name, version)
    if existing:
        if existing.get("sha1") != sha1:
            fail(f"{name} {version} already exists with a different SHA-1")
        print(f"portal upload: {name} {version} already matches ({sha1})")
        return 0

    api_key = os.environ.get(arguments.api_key_env)
    if not api_key:
        fail(f"{arguments.api_key_env} is not set")
    upload(path, name, api_key)
    wait_for_release(name, version, sha1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
