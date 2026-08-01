#!/usr/bin/env python3
"""Preview or apply the source-controlled Mod Portal description and metadata."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ENDPOINT = "https://mods.factorio.com/api/v2/mods/edit_details"
PUBLIC_DETAILS_ENDPOINT = "https://mods.factorio.com/api/mods/{mod}/full"
USER_AGENT = "Sceatorio-release/1 (+https://github.com/Sceat/sceatorio)"
PUBLIC_VERIFY_ATTEMPTS = 12


def payload() -> dict[str, str | list[str]]:
    metadata = json.loads((REPO_ROOT / "portal/metadata.json").read_text(encoding="utf-8"))
    info = json.loads((REPO_ROOT / "info.json").read_text(encoding="utf-8"))
    files = metadata["files"]
    return {
        "mod": info["name"],
        "title": info["title"],
        "summary": (REPO_ROOT / files["summary"]).read_text(encoding="utf-8").strip(),
        "description": (REPO_ROOT / files["description"]).read_text(encoding="utf-8"),
        "faq": (REPO_ROOT / files["faq"]).read_text(encoding="utf-8"),
        "category": metadata["category"],
        "tags": metadata["tags"],
        "license": metadata["license"],
        "homepage": info["homepage"],
        "source_url": metadata["source_url"],
        "deprecated": "false",
    }


def apply_details(values: dict[str, str | list[str]], api_key: str) -> None:
    body = urllib.parse.urlencode(values, doseq=True).encode("utf-8")
    request = urllib.request.Request(
        ENDPOINT,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(
            f"portal details: HTTP {error.code}: "
            f"{error.read().decode('utf-8', 'replace')[:500]}"
        ) from error
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise SystemExit(f"portal details: edit request failed: {error}") from error
    if result.get("success") is not True:
        raise SystemExit(
            "portal details: edit was not acknowledged: "
            f"{json.dumps(result, sort_keys=True)}"
        )


def public_details(mod: str) -> dict:
    url = PUBLIC_DETAILS_ENDPOINT.format(mod=urllib.parse.quote(mod, safe=""))
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(
            f"HTTP {error.code}: {error.read().decode('utf-8', 'replace')[:500]}"
        ) from error
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise RuntimeError(str(error)) from error
    if not isinstance(result, dict):
        raise RuntimeError("public details response is not an object")
    return result


def normalize_text(value: object) -> str:
    return str(value).replace("\r\n", "\n").replace("\r", "\n")


def public_mismatches(
    details: dict, values: dict[str, str | list[str]]
) -> list[str]:
    mismatches: list[str] = []
    for field in ("mod", "title", "summary", "category", "homepage", "source_url"):
        public_field = "name" if field == "mod" else field
        if details.get(public_field, "") != values[field]:
            mismatches.append(field)

    if normalize_text(details.get("description", "")) != normalize_text(
        values["description"]
    ):
        mismatches.append("description")

    public_tags = details.get("tags", [])
    expected_tags = values["tags"]
    if not isinstance(public_tags, list) or sorted(public_tags) != sorted(expected_tags):
        mismatches.append("tags")

    public_license = details.get("license", {})
    if not isinstance(public_license, dict) or public_license.get("id") != values["license"]:
        mismatches.append("license")

    expected_deprecated = values["deprecated"] == "true"
    if bool(details.get("deprecated", False)) != expected_deprecated:
        mismatches.append("deprecated")
    return mismatches


def verify_public_details(
    values: dict[str, str | list[str]], attempts: int = PUBLIC_VERIFY_ATTEMPTS
) -> None:
    last_problem = "no verification attempt was made"
    for attempt in range(1, attempts + 1):
        try:
            details = public_details(str(values["mod"]))
            mismatches = public_mismatches(details, values)
            if not mismatches:
                return
            last_problem = "public fields differ: " + ", ".join(mismatches)
        except RuntimeError as error:
            last_problem = f"public readback failed: {error}"
        if attempt < attempts:
            time.sleep(min(attempt * 2, 15))
    raise SystemExit(
        f"portal details: public verification failed after {attempts} attempts: "
        f"{last_problem}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="perform the authenticated edit")
    parser.add_argument(
        "--api-key-env",
        default="FACTORIO_MOD_PORTAL_API_KEY",
        help="environment variable containing a Mod Portal key with Edit Mods scope",
    )
    arguments = parser.parse_args()
    values = payload()
    if not arguments.apply:
        preview = dict(values)
        preview["description"] = "portal/description.md"
        preview["faq"] = "portal/faq.md"
        print(json.dumps(preview, indent=2, ensure_ascii=False, sort_keys=True))
        return 0

    api_key = os.environ.get(arguments.api_key_env)
    if not api_key:
        raise SystemExit(f"portal details: {arguments.api_key_env} is not set")
    apply_details(values, api_key)
    verify_public_details(values)
    print("portal details: update acknowledged and public fields verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
