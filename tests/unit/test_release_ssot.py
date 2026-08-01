import json
import sys
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
        defaults = {
            setting.name: setting.default
            for setting in sync_docs.parse_settings()
            if setting.name in {
                "sceatorio-ai-allowed-capabilities",
                "sceatorio-ai-requested-capabilities",
            }
        }

        self.assertEqual(len(expected.split(",")), 16)
        self.assertEqual(
            defaults,
            {
                "sceatorio-ai-allowed-capabilities": expected,
                "sceatorio-ai-requested-capabilities": expected,
            },
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

if __name__ == "__main__":
    unittest.main()
