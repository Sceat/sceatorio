#!/usr/bin/env python3
"""Build a deterministic, allowlisted Factorio mod archive."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import zipfile
from pathlib import Path
from typing import NoReturn


REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = Path(__file__).with_name("release-manifest.json")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def fail(message: str) -> NoReturn:
    raise SystemExit(f"package: {message}")


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {path.relative_to(REPO_ROOT)}: {error}")


def package_files() -> list[Path]:
    manifest = load_json(MANIFEST_PATH)
    if manifest.get("format_version") != 1:
        fail("unsupported release manifest format")

    selected: list[Path] = []
    for relative in manifest.get("root_files", []):
        path = REPO_ROOT / relative
        if not path.is_file() or path.is_symlink():
            fail(f"required regular file is missing: {relative}")
        selected.append(path)

    for relative, extensions in manifest.get("trees", {}).items():
        root = REPO_ROOT / relative
        if not root.is_dir() or root.is_symlink():
            fail(f"required source tree is missing: {relative}")
        allowed = set(extensions)
        for path in root.rglob("*"):
            if path.is_symlink():
                fail(f"symlinks are not allowed in a release: {path.relative_to(REPO_ROOT)}")
            if path.is_file():
                if path.suffix not in allowed:
                    fail(f"unallowlisted file in release tree: {path.relative_to(REPO_ROOT)}")
                selected.append(path)

    relative_names = [path.relative_to(REPO_ROOT).as_posix() for path in selected]
    if len(relative_names) != len(set(name.casefold() for name in relative_names)):
        fail("release paths collide when compared case-insensitively")
    return sorted(selected, key=lambda path: path.relative_to(REPO_ROOT).as_posix())


def archive_name() -> tuple[str, str]:
    info = load_json(REPO_ROOT / "info.json")
    name = info.get("name")
    version = info.get("version")
    if not isinstance(name, str) or not name or "/" in name or "\\" in name:
        fail("info.json has an invalid mod name")
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        fail("info.json version must use X.Y.Z")
    return f"{name}_{version}", version


def write_archive(output_directory: Path) -> Path:
    package_root, _ = archive_name()
    files = package_files()
    output_directory.mkdir(parents=True, exist_ok=True)
    archive = output_directory / f"{package_root}.zip"
    temporary = output_directory / f".{archive.name}.tmp"

    if temporary.exists():
        temporary.unlink()
    try:
        # Stored entries avoid zlib-version differences while remaining a valid ZIP.
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED) as bundle:
            for path in files:
                relative = path.relative_to(REPO_ROOT).as_posix()
                entry = zipfile.ZipInfo(f"{package_root}/{relative}", ZIP_TIMESTAMP)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                entry.compress_type = zipfile.ZIP_STORED
                bundle.writestr(entry, path.read_bytes())
        os.replace(temporary, archive)
    finally:
        if temporary.exists():
            temporary.unlink()
    return archive


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=REPO_ROOT / "dist",
        help="directory for the versioned ZIP (default: ./dist)",
    )
    arguments = parser.parse_args()
    archive = write_archive(arguments.output.resolve())
    print(archive)
    return 0


if __name__ == "__main__":
    sys.exit(main())
