#!/usr/bin/env python3
"""Validate release metadata, public contracts, assets, workflows, and archives."""

from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import re
import struct
import sys
import zipfile
import zlib
from pathlib import Path

import package as package_tool
import sync_docs


REPO_ROOT = Path(__file__).resolve().parents[1]
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
ACTION_PIN = re.compile(r"^\s*-?\s*uses:\s*[^\s@]+@[0-9a-f]{40}(?:\s*#.*)?$")
VALID_CATEGORIES = {
    "content", "internal", "localizations", "mod-packs", "no-category",
    "overhaul", "scenarios", "tweaks", "utilities",
}
VALID_TAGS = {
    "armor", "blueprints", "cheats", "circuit-network", "combat", "enemies",
    "environment", "fluids", "logistic-network", "logistics", "manufacturing",
    "mining", "planets", "power", "storage", "trains", "transportation",
}


class Validation:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)


def load_json(path: Path, validation: Validation) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        validation.require(isinstance(value, dict), f"{path.name} must contain an object")
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError) as error:
        validation.errors.append(f"cannot read {path.relative_to(REPO_ROOT)}: {error}")
        return {}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def png_dimensions(path: Path) -> tuple[int, int] | None:
    try:
        with path.open("rb") as stream:
            header = stream.read(24)
        if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
            return None
        return struct.unpack(">II", header[16:24])
    except OSError:
        return None


def png_chunk_types(path: Path) -> tuple[bytes, ...] | None:
    try:
        with path.open("rb") as stream:
            if stream.read(8) != b"\x89PNG\r\n\x1a\n":
                return None
            chunks: list[bytes] = []
            while True:
                raw_length = stream.read(4)
                chunk_type = stream.read(4)
                if len(raw_length) != 4 or len(chunk_type) != 4:
                    return None
                length = struct.unpack(">I", raw_length)[0]
                if len(stream.read(length)) != length or len(stream.read(4)) != 4:
                    return None
                chunks.append(chunk_type)
                if chunk_type == b"IEND":
                    return tuple(chunks)
    except OSError:
        return None


def png_has_c2pa_manifest(path: Path) -> bool:
    chunks = png_chunk_types(path)
    return chunks is not None and b"caBX" in chunks


def _paeth_predictor(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def png_rgba_alpha_stats(path: Path) -> dict[str, object] | None:
    """Read alpha statistics from a non-interlaced 8-bit RGBA PNG."""
    try:
        payload = path.read_bytes()
        if payload[:8] != b"\x89PNG\r\n\x1a\n":
            return None

        offset = 8
        header: tuple[int, int, int, int, int, int, int] | None = None
        compressed = bytearray()
        while offset + 12 <= len(payload):
            length = struct.unpack(">I", payload[offset:offset + 4])[0]
            chunk_type = payload[offset + 4:offset + 8]
            chunk_end = offset + 12 + length
            if chunk_end > len(payload):
                return None
            chunk = payload[offset + 8:offset + 8 + length]
            if chunk_type == b"IHDR":
                if length != 13:
                    return None
                header = struct.unpack(">IIBBBBB", chunk)
            elif chunk_type == b"IDAT":
                compressed.extend(chunk)
            elif chunk_type == b"IEND":
                break
            offset = chunk_end

        if header is None:
            return None
        width, height, bit_depth, color_type, compression, filtering, interlace = header
        if (
            width == 0
            or height == 0
            or bit_depth != 8
            or color_type != 6
            or compression != 0
            or filtering != 0
            or interlace != 0
        ):
            return None

        raw = zlib.decompress(bytes(compressed))
        bytes_per_pixel = 4
        stride = width * bytes_per_pixel
        if len(raw) != height * (stride + 1):
            return None

        previous = bytearray(stride)
        transparent = 0
        opaque = 0
        visible = 0
        min_x, min_y = width, height
        max_x = max_y = -1
        corners: dict[tuple[int, int], int] = {}
        position = 0
        corner_coordinates = {
            (0, 0),
            (width - 1, 0),
            (0, height - 1),
            (width - 1, height - 1),
        }

        for y in range(height):
            filter_type = raw[position]
            position += 1
            scanline = bytearray(raw[position:position + stride])
            position += stride
            if filter_type not in {0, 1, 2, 3, 4}:
                return None
            for index in range(stride):
                left = scanline[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
                above = previous[index]
                upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
                if filter_type == 1:
                    scanline[index] = (scanline[index] + left) & 0xFF
                elif filter_type == 2:
                    scanline[index] = (scanline[index] + above) & 0xFF
                elif filter_type == 3:
                    scanline[index] = (scanline[index] + ((left + above) // 2)) & 0xFF
                elif filter_type == 4:
                    scanline[index] = (
                        scanline[index] + _paeth_predictor(left, above, upper_left)
                    ) & 0xFF

            for x in range(width):
                alpha = scanline[x * bytes_per_pixel + 3]
                if (x, y) in corner_coordinates:
                    corners[(x, y)] = alpha
                if alpha == 0:
                    transparent += 1
                    continue
                visible += 1
                if alpha == 255:
                    opaque += 1
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y = max(max_y, y)
            previous = scanline

        bounds = None if visible == 0 else (min_x, min_y, max_x, max_y)
        return {
            "width": width,
            "height": height,
            "transparent": transparent,
            "opaque": opaque,
            "visible": visible,
            "bounds": bounds,
            "corner_alphas": tuple(corners[coordinate] for coordinate in sorted(corner_coordinates)),
        }
    except (OSError, struct.error, zlib.error):
        return None


def validate_transparent_icon(validation: Validation, path: Path, label: str) -> None:
    stats = png_rgba_alpha_stats(path)
    validation.require(stats is not None, f"{label} must be a non-interlaced 8-bit RGBA PNG")
    if stats is None:
        return

    width = int(stats["width"])
    height = int(stats["height"])
    total = width * height
    visible = int(stats["visible"])
    opaque = int(stats["opaque"])
    validation.require(
        all(alpha == 0 for alpha in stats["corner_alphas"]),
        f"{label} must have fully transparent corners",
    )
    validation.require(
        total // 10 <= visible <= total * 9 // 10,
        f"{label} visible alpha coverage must stay between 10% and 90%",
    )
    validation.require(
        opaque >= total // 20,
        f"{label} must retain meaningful fully opaque content",
    )

    bounds = stats["bounds"]
    validation.require(bounds is not None, f"{label} must contain visible pixels")
    if bounds is not None:
        min_x, min_y, max_x, max_y = bounds
        validation.require(
            min_x > 0 and min_y > 0 and max_x < width - 1 and max_y < height - 1,
            f"{label} visible bounds must retain transparent padding on every side",
        )
        validation.require(
            max_x - min_x + 1 >= width // 2 and max_y - min_y + 1 >= height // 2,
            f"{label} visible bounds must occupy at least half the canvas in each dimension",
        )


def validate_info(validation: Validation, expected_tag: str | None, factorio_target: str) -> dict:
    info = load_json(REPO_ROOT / "info.json", validation)
    version = info.get("version", "")
    validation.require(info.get("name") == "Sceatorio", "info.json name must stay Sceatorio")
    validation.require(bool(SEMVER.fullmatch(str(version))), "info.json version must use X.Y.Z")
    target_minor = ".".join(factorio_target.split(".")[:2])
    validation.require(info.get("factorio_version") == target_minor, f"info.json must target Factorio {target_minor}")
    dependencies = info.get("dependencies", [])
    validation.require(f"base >= {factorio_target}" in dependencies, f"base dependency must require Factorio {factorio_target}")
    validation.require(
        f"? space-age >= {factorio_target}" in dependencies,
        f"Space Age must remain an optional {factorio_target} dependency",
    )
    if expected_tag:
        validation.require(expected_tag == f"v{version}", f"tag {expected_tag!r} must equal v{version}")

    changelog = (REPO_ROOT / "changelog.txt").read_text(encoding="utf-8")
    match = re.search(r"^Version:\s*([^\s]+)\s*$", changelog, re.M)
    validation.require(bool(match), "changelog.txt has no Version entry")
    if match:
        validation.require(match.group(1) == version, "top changelog version must match info.json")
    return info


def validate_headless_ci(validation: Validation) -> str:
    matrix = load_json(REPO_ROOT / "tests/headless/matrix.json", validation)
    factorio = matrix.get("factorio", {})
    version = str(factorio.get("version", ""))
    headless = factorio.get("headless", {})
    filename = headless.get("filename", "")
    url = headless.get("url", "")
    checksum = headless.get("sha256", "")
    validation.require(bool(SEMVER.fullmatch(version)), "headless matrix Factorio version must use X.Y.Z")
    validation.require(
        filename == f"factorio-headless_linux_{version}.tar.xz",
        "headless filename must contain the exact matrix version",
    )
    validation.require(
        url == f"https://factorio.com/get-download/{version}/headless/linux64",
        "headless URL must be the exact official version URL",
    )
    validation.require(
        bool(re.fullmatch(r"[0-9a-f]{64}", str(checksum))),
        "headless archive must have an exact lowercase SHA-256",
    )

    ci = (REPO_ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    release = (REPO_ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    suite = (REPO_ROOT / "tests/headless/ci.sh").read_text(encoding="utf-8")
    for workflow_name, workflow in (("CI", ci), ("release", release)):
        validation.require("headless-env" in workflow, f"{workflow_name} must read headless provenance from matrix.json")
        validation.require("sha256sum --check --strict" in workflow, f"{workflow_name} must verify the headless SHA-256")
        validation.require("sh tests/headless/ci.sh" in workflow, f"{workflow_name} must run the real-engine suite")
        validation.require(str(checksum) not in workflow, f"{workflow_name} must not duplicate the headless checksum")
        validation.require(str(url) not in workflow, f"{workflow_name} must not duplicate the headless URL")
        validation.require("get-download/latest" not in workflow, f"{workflow_name} must never download latest")
    for command in (
        'sh "$RUNNER" smoke all',
        'sh "$RUNNER" server space-age',
        'sh "$RUNNER" fixture base security',
        'sh "$RUNNER" mod-fixture base all',
        'sh "$RUNNER" mod-fixture space-age space-age-planets',
        'sh "$RUNNER" ai-e2e base',
    ):
        validation.require(command in suite, f"headless CI suite omits: {command}")
    validation.require("required-server" not in suite, "headless CI must not request blocked third-party artifacts")
    return version


def validate_portal(validation: Validation, info: dict) -> None:
    metadata = load_json(REPO_ROOT / "portal/metadata.json", validation)
    files = metadata.get("files", {})
    if not isinstance(files, dict):
        validation.errors.append("portal metadata files must contain an object")
        files = {}
    asset_manifest = load_json(REPO_ROOT / "portal/assets/manifest.json", validation)
    expected_files = {
        "summary": "portal/summary.txt",
        "description": "portal/description.md",
        "faq": "portal/faq.md",
        "thumbnail": asset_manifest.get("selected_portal_thumbnail"),
        "gallery_plan": "portal/gallery-capture.md",
    }
    validation.require(files == expected_files, "portal metadata file pointers drift from canonical sources")
    summary = (REPO_ROOT / expected_files["summary"]).read_text(encoding="utf-8").strip()
    description = (REPO_ROOT / expected_files["description"]).read_text(encoding="utf-8")
    faq = (REPO_ROOT / expected_files["faq"]).read_text(encoding="utf-8")
    contract = load_json(REPO_ROOT / "portal/feature-contract.json", validation)

    validation.require("\n" not in summary, "portal summary must be one line")
    validation.require(1 <= len(summary) <= 500, "portal summary must be 1..500 characters")
    for duplicated in ("mod", "title", "summary", "homepage"):
        validation.require(
            duplicated not in metadata,
            f"portal metadata must not duplicate canonical info/summary field: {duplicated}",
        )
    validation.require(info.get("description") == summary, "info.json description and portal summary drift")
    validation.require(metadata.get("category") == "scenarios", "portal category must be scenarios")
    validation.require(metadata.get("category") in VALID_CATEGORIES, "portal category is invalid")
    tags = metadata.get("tags", [])
    validation.require(isinstance(tags, list) and bool(tags), "portal tags must be a non-empty list")
    validation.require(set(tags) <= VALID_TAGS, "portal metadata contains an unsupported tag")
    validation.require("planets" in tags, "Space Age support must remain discoverable through the planets tag")
    validation.require("multiplayer" not in tags, "the Mod Portal has no multiplayer tag")
    validation.require(metadata.get("license") == "default_mit", "portal license must match LICENSE")

    for entry in contract.get("implemented", []) + contract.get("limitations", []):
        phrase = entry.get("portal_phrase")
        if phrase:
            validation.require(phrase in description or phrase in faq, f"portal copy omits contract phrase: {phrase}")
        for evidence in entry.get("evidence", []):
            path = REPO_ROOT / evidence["path"]
            validation.require(path.is_file(), f"feature evidence is missing: {evidence['path']}")
            if path.is_file() and evidence.get("contains"):
                validation.require(
                    evidence["contains"] in path.read_text(encoding="utf-8"),
                    f"feature evidence token is missing: {evidence['path']}::{evidence['contains']}",
                )

    combined = description + "\n" + faq
    validation.require("Offline protection activates immediately" in combined, "immediate offline-protection behavior must be prominent")
    validation.require("There is no grace timer" in combined, "offline-protection copy must explicitly reject a grace timer")
    validation.require(
        "Connected players and team radars share their nearby, already-generated map discovery"
        in combined,
        "bounded registered-team chart sharing must be prominent",
    )
    validation.require("no retrofit guarantee" in combined, "fresh-world offline-registration limitation must be prominent")
    validation.require(
        "unrelated entities created without any Factorio lifecycle event remain a trusted-mod boundary"
        in combined,
        "unannounced third-party electricity limitation must be prominent",
    )
    validation.require("24 scoped MCP tools" in combined, "portal copy must describe the shipped 24-tool AI boundary")
    validation.require("bearer credentials never enter Factorio UDP or the save" in combined, "portal copy must state the AI credential boundary")
    validation.require(
        "not affiliated with or endorsed by Anthropic" in description,
        "portal description must disclose that the Claude-referencing icon is unofficial",
    )


def validate_assets(validation: Validation) -> None:
    manifest = load_json(REPO_ROOT / "portal/assets/manifest.json", validation)
    audit = manifest.get("c2pa_audit", {})
    validation.require(
        audit.get("audited_ai_source") == "portal/assets/ai-assistance-source-v2.png",
        "C2PA audit must name the source that was actually inspected",
    )
    validation.require(
        audit.get("audited_ai_source_claim_generator") == "OpenAI Media Service API",
        "C2PA audit claim generator must describe the audited source",
    )
    validation.require(
        audit.get("audited_ai_source_spec_version") == "2.2.0",
        "C2PA audit spec version must describe the audited source",
    )
    validation.require(
        "selected_ai_source_claim_generator" not in audit
        and "selected_ai_source_spec_version" not in audit,
        "C2PA audit must not attribute v2 inspection results to the selected v3 source",
    )
    entries = manifest.get("files", [])
    for entry in entries:
        path = REPO_ROOT / entry["path"]
        validation.require(path.is_file(), f"asset is missing: {entry['path']}")
        if path.is_file():
            validation.require(sha256(path) == entry.get("sha256"), f"asset hash drift: {entry['path']}")
            validation.require(list(png_dimensions(path) or ()) == entry.get("dimensions"), f"asset dimensions drift: {entry['path']}")
            expected_c2pa = entry.get("c2pa_manifest")
            validation.require(isinstance(expected_c2pa, bool), f"asset C2PA flag is missing: {entry['path']}")
            if isinstance(expected_c2pa, bool):
                validation.require(
                    png_has_c2pa_manifest(path) == expected_c2pa,
                    f"asset C2PA presence drift: {entry['path']}",
                )
    selected = REPO_ROOT / manifest.get("selected_portal_thumbnail", "")
    root = REPO_ROOT / "thumbnail.png"
    validation.require(selected.is_file(), "selected portal thumbnail is missing")
    if selected.is_file() and root.is_file():
        validation.require(root.read_bytes() == selected.read_bytes(), "root thumbnail must equal selected portal thumbnail")
    validation.require(png_dimensions(root) == (256, 256), "root thumbnail must be a 256x256 PNG")

    selected_ai_relative = manifest.get("selected_ai_assistance_icon", "")
    selected_ai_source_relative = manifest.get("selected_ai_assistance_source", "")
    selected_ai_master_relative = manifest.get("selected_ai_assistance_master", "")
    selected_ai = REPO_ROOT / selected_ai_relative
    selected_ai_source = REPO_ROOT / selected_ai_source_relative
    selected_ai_master = REPO_ROOT / selected_ai_master_relative
    validation.require(selected_ai.is_file(), "selected AI Assistance runtime icon is missing")
    validation.require(selected_ai_source.is_file(), "selected AI Assistance generated source is missing")
    validation.require(selected_ai_master.is_file(), "selected AI Assistance transparent master is missing")
    validation.require(png_dimensions(selected_ai) == (256, 256), "AI Assistance runtime icon must be 256x256")
    by_path = {entry.get("path"): entry for entry in entries}
    validation.require(selected_ai_relative in by_path, "selected AI Assistance runtime icon is absent from the asset manifest")
    validation.require(selected_ai_source_relative in by_path, "selected AI Assistance source is absent from the asset manifest")
    validation.require(selected_ai_master_relative in by_path, "selected AI Assistance master is absent from the asset manifest")
    if selected_ai_master.is_file():
        validate_transparent_icon(validation, selected_ai_master, "AI Assistance transparent master")
        master_entry = by_path.get(selected_ai_master_relative, {})
        recipe = master_entry.get("derived_with", "")
        for token in (
            "python3",
            "remove_chroma_key.py",
            f"--input {selected_ai_source_relative}",
            f"--out {selected_ai_master_relative}",
            "--auto-key border",
            "--soft-matte",
            "--transparent-threshold 12",
            "--opaque-threshold 220",
            "--despill",
            "--force",
        ):
            validation.require(token in recipe, f"AI Assistance chroma recipe must include {token!r}")
        validation.require(
            bool(re.fullmatch(r"[0-9a-f]{64}", str(master_entry.get("derivation_tool_sha256", "")))),
            "AI Assistance chroma recipe must record its helper SHA-256",
        )
    if selected_ai.is_file():
        validate_transparent_icon(validation, selected_ai, "AI Assistance runtime icon")
    data_stage = (REPO_ROOT / "data.lua").read_text(encoding="utf-8")
    validation.require(
        f'"__Sceatorio__/{selected_ai_relative}"' in data_stage,
        "data.lua AI Assistance icon path must match the selected asset manifest entry",
    )
    validation.require(
        "AI_ASSISTANCE_ICON_SIZE = 256" in data_stage,
        "data.lua AI Assistance icon size must match the selected 256px runtime asset",
    )


def validate_workflows(validation: Validation) -> None:
    workflows = list((REPO_ROOT / ".github/workflows").glob("*.yml")) + list((REPO_ROOT / ".github/workflows").glob("*.yaml"))
    validation.require(bool(workflows), "no GitHub Actions workflows found")
    for workflow in workflows:
        for number, line in enumerate(workflow.read_text(encoding="utf-8").splitlines(), 1):
            if re.match(r"^\s*-?\s*uses:", line):
                validation.require(bool(ACTION_PIN.fullmatch(line)), f"{workflow.name}:{number} action is not pinned to a full SHA")
    validation.require(not (REPO_ROOT / "release.sh").exists(), "unsafe legacy release.sh must stay removed")
    validation.require(not (REPO_ROOT / "local_test.sh").exists(), "unsafe legacy local_test.sh must stay removed")
    release = (REPO_ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    for token in (
        "github.event.repository.default_branch",
        "git fetch --no-tags origin",
        "git merge-base --is-ancestor",
        "refs/remotes/origin/$DEFAULT_BRANCH",
        "FACTORIO_MOD_PORTAL_API_KEY",
        "python3 scripts/update_portal_details.py --apply",
    ):
        validation.require(token in release, f"release workflow omits hardening token: {token}")


def validate_third_party_audit(validation: Validation, factorio_target: str) -> None:
    lock = load_json(
        REPO_ROOT / "docs/third-party/added-mods-2.1.12.lock.json",
        validation,
    )
    target = lock.get("target", {})
    validation.require(
        target.get("factorio_version") == factorio_target,
        "third-party audit target must match the headless Factorio target",
    )
    validation.require(
        lock.get("production_lock") is False,
        "third-party audit proposal must not present itself as a production lock",
    )

    approved = lock.get("approved_mods", [])
    blocked = lock.get("blocked_candidates", [])
    validation.require(isinstance(approved, list), "approved_mods must be a list")
    validation.require(isinstance(blocked, list), "blocked_candidates must be a list")
    approved = approved if isinstance(approved, list) else []
    blocked = blocked if isinstance(blocked, list) else []

    names: set[str] = set()
    for entry, expected_enabled in (
        *((item, True) for item in approved),
        *((item, False) for item in blocked),
    ):
        name = str(entry.get("name", ""))
        version = str(entry.get("version", ""))
        validation.require(bool(name), "third-party audit entry has no name")
        validation.require(name not in names, f"duplicate third-party audit entry: {name}")
        names.add(name)
        validation.require(bool(SEMVER.fullmatch(version)), f"invalid audited version for {name}")
        validation.require(
            entry.get("file_name") == f"{name}_{version}.zip",
            f"audited filename does not match name/version for {name}",
        )
        validation.require(
            bool(re.fullmatch(r"[0-9a-f]{40}", str(entry.get("sha1", "")))),
            f"audited Portal SHA-1 is missing or invalid for {name}",
        )
        deployment = entry.get("deployment", {})
        validation.require(
            deployment.get("enabled") is expected_enabled,
            f"audited deployment enabled state disagrees with its list for {name}",
        )

    aai = next(
        (entry for entry in blocked if entry.get("name") == "aai-signal-transmission"),
        None,
    )
    validation.require(aai is not None, "AAI Signal Transmission must remain explicitly release-gated")
    if aai:
        validation.require(aai.get("version") == "0.6.0", "AAI Signal Transmission version pin drift")
        validation.require(
            aai.get("sha1") == "c6606a442a66d77eab8c8341a0e84a6c63b50197",
            "AAI Signal Transmission official Portal SHA-1 drift",
        )
        verification = aai.get("verification", {})
        validation.require(
            verification.get("exact_portal_artifact_tested") is False,
            "AAI Signal Transmission cannot be approved without exact-artifact evidence",
        )

def validate_archive(validation: Validation, archive: Path, info: dict) -> None:
    validation.require(archive.is_file(), f"archive does not exist: {archive}")
    if not archive.is_file():
        return
    root = f"{info['name']}_{info['version']}"
    expected = {f"{root}/{path.relative_to(REPO_ROOT).as_posix()}" for path in package_tool.package_files()}
    try:
        with zipfile.ZipFile(archive) as bundle:
            names = bundle.namelist()
            validation.require(len(names) == len(set(names)), "archive contains duplicate names")
            validation.require(set(names) == expected, "archive entries differ from the release allowlist")
            validation.require(f"{root}/data.lua" in names, "archive must include data.lua runtime prototypes")
            validation.require(
                f"{root}/THIRD_PARTY.md" in names,
                "archive must include the notice for its trademark-referencing AI Assistance icon",
            )
            validation.require(
                f"{root}/graphics/technology/ai-assistance.png" in names,
                "archive must include the AI Assistance technology icon",
            )
            for entry in bundle.infolist():
                validation.require(entry.date_time == package_tool.ZIP_TIMESTAMP, f"archive timestamp is not deterministic: {entry.filename}")
                validation.require(entry.filename.startswith(root + "/"), f"archive has the wrong root: {entry.filename}")
    except zipfile.BadZipFile as error:
        validation.errors.append(f"archive is not a valid ZIP: {error}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="release tag to compare with info.json (must be vX.Y.Z)")
    parser.add_argument("--archive", type=Path, help="also validate a built archive")
    arguments = parser.parse_args()
    validation = Validation()

    validation.require((REPO_ROOT / "README.md").is_file(), "canonical README.md is missing")
    validation.require(
        not any(path.name == "README.MD" for path in REPO_ROOT.iterdir()),
        "README.MD must stay renamed to README.md",
    )
    validation.require((REPO_ROOT / "LICENSE").read_text(encoding="utf-8").startswith("MIT License\n"), "LICENSE must contain the MIT text")
    factorio_target = validate_headless_ci(validation)
    info = validate_info(validation, arguments.tag, factorio_target)
    validate_portal(validation, info)
    validate_assets(validation)
    validate_workflows(validation)
    validate_third_party_audit(validation, factorio_target)

    try:
        for setting in sync_docs.parse_settings():
            validation.require(setting.name.startswith("sceatorio-"), f"unscoped setting name: {setting.name}")
    except (OSError, ValueError, KeyError, configparser.Error) as error:
        validation.errors.append(f"cannot validate settings: {error}")
    validation.require(sync_docs.compare(sync_docs.SETTINGS_OUTPUT, sync_docs.render_settings()), "generated settings reference drift")
    validation.require(sync_docs.compare(sync_docs.FEATURE_OUTPUT, sync_docs.render_features()), "generated feature reference drift")

    if arguments.archive:
        validate_archive(validation, arguments.archive.resolve(), info)

    if validation.errors:
        for error in validation.errors:
            print(f"validate: {error}", file=sys.stderr)
        return 1
    print("validate: release metadata, public contracts, assets, and workflows are consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
