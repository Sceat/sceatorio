import json
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import sync_docs  # noqa: E402
import validate as release_validate  # noqa: E402


class ReleaseSingleSourceOfTruthTests(unittest.TestCase):
    def test_portal_metadata_points_to_canonical_public_sources(self):
        metadata = json.loads(
            (REPO_ROOT / "portal/metadata.json").read_text(encoding="utf-8")
        )
        manifest = json.loads(
            (REPO_ROOT / "portal/assets/manifest.json").read_text(encoding="utf-8")
        )

        for duplicated in ("mod", "title", "summary", "homepage"):
            self.assertNotIn(duplicated, metadata)
        self.assertEqual(
            metadata["files"],
            {
                "summary": "portal/summary.txt",
                "description": "portal/description.md",
                "faq": "portal/faq.md",
                "thumbnail": manifest["selected_portal_thumbnail"],
                "gallery_plan": "portal/gallery-capture.md",
            },
        )

    def test_ai_capability_setting_defaults_come_from_lua_constants(self):
        expected = sync_docs.default_capabilities_csv()
        settings = sync_docs.parse_settings()
        defaults = {
            setting.name: setting.default
            for setting in settings
            if setting.name == "sceatorio-ai-allowed-capabilities"
        }

        self.assertEqual(len(expected.split(",")), 16)
        self.assertEqual(
            defaults,
            {"sceatorio-ai-allowed-capabilities": expected},
        )
        # 2.0.9 removed the per-player narrowing list: the server allowlist is
        # the only capability policy, so every setting is runtime-global.
        names = {setting.name for setting in settings}
        self.assertNotIn("sceatorio-ai-requested-capabilities", names)
        self.assertEqual(
            {setting.scope for setting in settings}, {"runtime-global"}
        )

    def test_ai_icon_provenance_and_runtime_selection_are_machine_checked(self):
        manifest = json.loads(
            (REPO_ROOT / "portal/assets/manifest.json").read_text(encoding="utf-8")
        )
        entries = {entry["path"]: entry for entry in manifest["files"]}
        superseded_derivative = "portal/assets/ai-assistance-v1.png"
        self.assertNotIn(superseded_derivative, entries)
        self.assertFalse((REPO_ROOT / superseded_derivative).exists())
        runtime_path = manifest["selected_ai_assistance_icon"]
        source_path = manifest["selected_ai_assistance_source"]
        master_path = manifest["selected_ai_assistance_master"]

        self.assertEqual(runtime_path, "graphics/technology/ai-assistance.png")
        self.assertEqual(source_path, "portal/assets/ai-assistance-source-v3.png")
        self.assertEqual(master_path, "portal/assets/ai-assistance-v3.png")
        self.assertEqual(entries[runtime_path]["dimensions"], [256, 256])
        self.assertTrue(entries[source_path]["c2pa_manifest"])
        self.assertTrue(release_validate.png_has_c2pa_manifest(REPO_ROOT / source_path))
        self.assertFalse(entries[runtime_path]["c2pa_manifest"])
        self.assertFalse(release_validate.png_has_c2pa_manifest(REPO_ROOT / runtime_path))

        audit = manifest["c2pa_audit"]
        self.assertEqual(
            audit["audited_ai_source"],
            "portal/assets/ai-assistance-source-v2.png",
        )
        self.assertEqual(
            audit["audited_ai_source_claim_generator"],
            "OpenAI Media Service API",
        )
        self.assertEqual(audit["audited_ai_source_spec_version"], "2.2.0")
        self.assertNotIn("selected_ai_source_claim_generator", audit)
        self.assertNotIn("selected_ai_source_spec_version", audit)

        master_entry = entries[master_path]
        self.assertEqual(
            master_entry["derivation_tool_sha256"],
            "3f7b9b14ad5c90f37618bc1c16a039a2076abca12ddc41b3ae470e2b1cad6c0e",
        )
        recipe = master_entry["derived_with"]
        for token in (
            "python3",
            "remove_chroma_key.py",
            f"--input {source_path}",
            f"--out {master_path}",
            "--auto-key border",
            "--soft-matte",
            "--transparent-threshold 12",
            "--opaque-threshold 220",
            "--despill",
            "--force",
        ):
            self.assertIn(token, recipe)

        for relative in (master_path, runtime_path):
            stats = release_validate.png_rgba_alpha_stats(REPO_ROOT / relative)
            self.assertIsNotNone(stats)
            self.assertEqual(stats["corner_alphas"], (0, 0, 0, 0))
            self.assertGreater(stats["visible"], stats["width"] * stats["height"] // 10)
            self.assertIsNotNone(stats["bounds"])
            validation = release_validate.Validation()
            release_validate.validate_transparent_icon(
                validation,
                REPO_ROOT / relative,
                relative,
            )
            self.assertEqual(validation.errors, [])

        data = (REPO_ROOT / "data.lua").read_text(encoding="utf-8")
        self.assertIn(f'"__Sceatorio__/{runtime_path}"', data)
        self.assertIn("AI_ASSISTANCE_ICON_SIZE = 256", data)

    def test_trademark_notice_is_public_and_shipped_with_the_icon(self):
        required = "not affiliated with or endorsed by Anthropic"
        for relative in ("README.md", "portal/description.md", "THIRD_PARTY.md"):
            self.assertIn(required, (REPO_ROOT / relative).read_text(encoding="utf-8"))

        release_manifest = json.loads(
            (REPO_ROOT / "scripts/release-manifest.json").read_text(encoding="utf-8")
        )
        self.assertIn("THIRD_PARTY.md", release_manifest["root_files"])

    def test_existing_github_release_is_verified_instead_of_overwritten(self):
        workflow = (REPO_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )

        for token in (
            'if gh release view "$RELEASE_TAG"',
            'gh release download "$RELEASE_TAG"',
            'cmp "$archive" "$verification_dir/$archive_name"',
            'cmp "$checksum" "$verification_dir/$checksum_name"',
            'gh release create "$RELEASE_TAG"',
            "--verify-tag",
        ):
            self.assertIn(token, workflow)

    def test_release_requires_default_branch_ancestry_and_verified_portal_copy(self):
        workflow = (REPO_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )

        for token in (
            "github.event.repository.default_branch",
            "git fetch --no-tags origin",
            "git merge-base --is-ancestor",
            "refs/remotes/origin/$DEFAULT_BRANCH",
            "FACTORIO_MOD_PORTAL_API_KEY",
            "python3 scripts/update_portal_details.py --apply",
        ):
            self.assertIn(token, workflow)

        self.assertIn("permissions:\n  contents: read", workflow)

    def test_single_portal_credential_is_required_before_any_publication(self):
        workflow = (REPO_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        preflight_start = workflow.index(
            "Require the scoped Mod Portal credential before publication"
        )
        upload_start = workflow.index(
            "Publish and verify through the official Mod Portal v2 API"
        )
        presentation_start = workflow.index(
            "Publish and verify Mod Portal presentation"
        )
        self.assertLess(preflight_start, upload_start)
        self.assertLess(preflight_start, presentation_start)

        preflight = workflow[preflight_start:upload_start]
        secret = "FACTORIO_MOD_PORTAL_API_KEY"
        self.assertIn(f"{secret}: ${{{{ secrets.{secret} }}}}", preflight)
        self.assertIn(f'test -n "${secret}"', preflight)

        presentation = workflow[presentation_start:]
        self.assertIn(f"{secret}: ${{{{ secrets.{secret} }}}}", presentation)

    def test_aai_signal_transmission_is_pinned_but_not_release_approved(self):
        lock = json.loads(
            (REPO_ROOT / "docs/third-party/added-mods-2.1.12.lock.json").read_text(
                encoding="utf-8"
            )
        )
        approved = {entry["name"]: entry for entry in lock["approved_mods"]}
        blocked = {entry["name"]: entry for entry in lock["blocked_candidates"]}

        self.assertNotIn("aai-signal-transmission", approved)
        entry = blocked["aai-signal-transmission"]
        self.assertEqual(entry["version"], "0.6.0")
        self.assertEqual(
            entry["sha1"], "c6606a442a66d77eab8c8341a0e84a6c63b50197"
        )
        self.assertFalse(entry["deployment"]["enabled"])
        self.assertFalse(entry["verification"]["exact_portal_artifact_tested"])


def write_catalog(directory: Path, names: list[str]) -> Path:
    """Write a stand-in mcp/src/catalog/tools.ts declaring exactly these tools."""
    entries = "\n".join(
        "  tool({\n"
        f'    name: "{name}",\n'
        f'    operation: "fixture.{name}",\n'
        "    readOnly: true\n"
        "  }),"
        for name in names
    )
    source = directory / "tools.ts"
    source.write_text(
        f"export const V1_TOOL_DEFINITIONS = [\n{entries}\n] as const;\n", encoding="utf-8"
    )
    return source


class McpToolCountDerivationTests(unittest.TestCase):
    """The shipped tool count is derived from the catalog, never asserted as a literal."""

    def test_catalog_parses_without_a_built_dist_or_node_modules(self):
        validation = release_validate.Validation()
        names = release_validate.mcp_tool_names(validation)

        self.assertEqual(validation.errors, [])
        self.assertGreater(len(names), 0)
        self.assertEqual(len(set(names)), len(names))
        self.assertIn("get_session", names)

    def test_derived_count_follows_the_catalog_rather_than_a_literal(self):
        with tempfile.TemporaryDirectory() as directory:
            source = write_catalog(Path(directory), ["get_session", "get_alerts", "get_trains"])
            validation = release_validate.Validation()

            names = release_validate.mcp_tool_names(validation, source=source)

            self.assertEqual(validation.errors, [])
            self.assertEqual(names, ["get_session", "get_alerts", "get_trains"])

    def test_unreadable_or_unparsable_catalog_fails_loudly(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "tools.ts"
            validation = release_validate.Validation()
            self.assertEqual(release_validate.mcp_tool_names(validation, source=missing), [])
            self.assertTrue(validation.errors)

            missing.write_text("export const SOMETHING_ELSE = [];\n", encoding="utf-8")
            validation = release_validate.Validation()
            self.assertEqual(release_validate.mcp_tool_names(validation, source=missing), [])
            self.assertTrue(validation.errors)

    def test_unnamed_catalog_entry_cannot_silently_shrink_the_count(self):
        with tempfile.TemporaryDirectory() as directory:
            source = write_catalog(Path(directory), ["get_session", "get_alerts"])
            source.write_text(
                source.read_text(encoding="utf-8").replace(
                    '    name: "get_alerts",\n', "    name:\n      \"get_alerts\",\n"
                ),
                encoding="utf-8",
            )
            validation = release_validate.Validation()

            release_validate.mcp_tool_names(validation, source=source)

            self.assertTrue(validation.errors)

    def test_stale_prose_count_fails_the_gate(self):
        # The counts stay interpolated: this file is itself scanned by the check under test.
        shipped, stale = 3, 4
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs").mkdir()
            (root / "README.md").write_text(
                f"ships {shipped} scoped MCP tools.\n", encoding="utf-8"
            )
            (root / "docs/gate.md").write_text(
                f"the {stale}-tool gateway is verified\n", encoding="utf-8"
            )
            pages = [root / "README.md", root / "docs/gate.md"]

            validation = release_validate.Validation()
            release_validate.validate_tool_count_claims(validation, shipped, pages)

            self.assertEqual(len(validation.errors), 1)
            self.assertIn("docs/gate.md:1", validation.errors[0])
            self.assertIn(f"'{stale}-tool'", validation.errors[0])

            (root / "docs/gate.md").write_text(
                f"the {shipped}-tool gateway is verified\n", encoding="utf-8"
            )
            validation = release_validate.Validation()
            release_validate.validate_tool_count_claims(validation, shipped, pages)
            self.assertEqual(validation.errors, [])

    def test_scanner_reports_when_it_covers_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            page = Path(directory) / "README.md"
            page.write_text("no counts here\n", encoding="utf-8")
            validation = release_validate.Validation()

            release_validate.validate_tool_count_claims(validation, 3, [page])

            self.assertTrue(validation.errors)

    def test_scan_covers_versioned_prose_but_not_untracked_scratch(self):
        validation = release_validate.Validation()
        tracked = release_validate.tracked_text_files(validation)

        self.assertEqual(validation.errors, [])
        self.assertIn(REPO_ROOT / "README.md", tracked)
        self.assertIn(REPO_ROOT / "portal/faq.md", tracked)
        self.assertIn(REPO_ROOT / "mcp/README.md", tracked)
        self.assertNotIn(REPO_ROOT / "changelog.txt", tracked)
        self.assertFalse([path for path in tracked if "node_modules" in path.parts])

    def test_claim_pattern_reads_prose_without_chasing_incidental_digits(self):
        count = 7
        self.assertEqual(
            release_validate.TOOL_COUNT_CLAIM.findall(
                f"exposes {count} low-level, scope-checked MCP tools for telemetry"
            ),
            [str(count)],
        )
        for text in ("the v1 tool catalog", "7z2patool binary", "at most 32 signals"):
            self.assertEqual(release_validate.TOOL_COUNT_CLAIM.findall(text), [])

    def test_every_prose_site_that_states_a_count_is_covered(self):
        validation = release_validate.Validation()
        paths = release_validate.tracked_text_files(validation)

        # No catalog can declare this many tools, so every covered claim must report.
        release_validate.validate_tool_count_claims(validation, 10**6, paths)

        reported = {error.split(" in ")[1].split(":")[0] for error in validation.errors}
        self.assertEqual(
            reported,
            {
                "README.md",
                "docs/features.md",
                "mcp/README.md",
                "portal/description.md",
                "portal/faq.md",
                "portal/feature-contract.json",
            },
        )

    def test_shipped_prose_matches_the_shipped_catalog(self):
        validation = release_validate.Validation()
        expected = len(release_validate.mcp_tool_names(validation))

        release_validate.validate_tool_count_claims(
            validation, expected, release_validate.tracked_text_files(validation)
        )

        self.assertEqual(validation.errors, [])
        combined = "\n".join(
            (REPO_ROOT / name).read_text(encoding="utf-8")
            for name in ("portal/description.md", "portal/faq.md")
        )
        self.assertIn(f"{expected} scoped MCP tools", combined)


if __name__ == "__main__":
    unittest.main()
