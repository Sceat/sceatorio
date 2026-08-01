import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import update_portal_details as portal_details  # noqa: E402


def expected_values():
    return {
        "mod": "Sceatorio",
        "title": "Sceatorio title",
        "summary": "Summary",
        "description": "First line\nSecond line\n",
        "faq": "FAQ text\n",
        "category": "scenarios",
        "tags": ["planets", "logistics"],
        "license": "default_mit",
        "homepage": "https://example.invalid/home",
        "source_url": "https://example.invalid/source",
        "deprecated": "false",
    }


def public_values():
    values = expected_values()
    return {
        "name": values["mod"],
        "title": values["title"],
        "summary": values["summary"],
        "description": values["description"].replace("\n", "\r\n"),
        "category": values["category"],
        "tags": list(reversed(values["tags"])),
        "license": {"id": values["license"], "name": "MIT"},
        "homepage": values["homepage"],
        "source_url": values["source_url"],
    }


class PortalDetailsTests(unittest.TestCase):
    def test_source_payload_includes_the_faq_and_all_public_fields(self):
        values = portal_details.payload()
        info = json.loads((REPO_ROOT / "info.json").read_text(encoding="utf-8"))

        self.assertEqual(values["mod"], info["name"])
        self.assertEqual(values["title"], info["title"])
        self.assertEqual(values["homepage"], info["homepage"])
        self.assertTrue(values["description"])
        self.assertTrue(values["faq"])
        for field in (
            "title",
            "summary",
            "category",
            "tags",
            "license",
            "homepage",
            "source_url",
            "deprecated",
        ):
            self.assertIn(field, values)

    def test_public_comparison_normalizes_newlines_and_tag_order(self):
        self.assertEqual(
            portal_details.public_mismatches(public_values(), expected_values()), []
        )

    def test_public_comparison_reports_every_checked_field(self):
        details = public_values()
        details.update(
            {
                "name": "Wrong",
                "title": "Wrong",
                "summary": "Wrong",
                "description": "Wrong",
                "category": "utility",
                "tags": ["planets"],
                "license": {"id": "other"},
                "homepage": "Wrong",
                "source_url": "Wrong",
                "deprecated": True,
            }
        )

        self.assertEqual(
            set(portal_details.public_mismatches(details, expected_values())),
            {
                "mod",
                "title",
                "summary",
                "description",
                "category",
                "tags",
                "license",
                "homepage",
                "source_url",
                "deprecated",
            },
        )

    @mock.patch.object(portal_details.time, "sleep")
    @mock.patch.object(portal_details, "public_details")
    def test_public_verification_retries_until_values_are_visible(
        self, readback, sleep
    ):
        stale = public_values()
        stale["summary"] = "Old summary"
        readback.side_effect = [stale, public_values()]

        portal_details.verify_public_details(expected_values(), attempts=2)

        self.assertEqual(readback.call_count, 2)
        sleep.assert_called_once_with(2)

    @mock.patch.object(portal_details.time, "sleep")
    @mock.patch.object(portal_details, "public_details")
    def test_public_verification_fails_closed_after_bounded_retries(
        self, readback, sleep
    ):
        stale = public_values()
        stale["summary"] = "Old summary"
        readback.return_value = stale

        with self.assertRaisesRegex(SystemExit, "public fields differ: summary"):
            portal_details.verify_public_details(expected_values(), attempts=2)

        self.assertEqual(readback.call_count, 2)
        sleep.assert_called_once_with(2)

    @mock.patch.object(portal_details, "verify_public_details")
    @mock.patch.object(portal_details, "apply_details")
    @mock.patch.object(portal_details, "payload", return_value=expected_values())
    def test_apply_acknowledgement_is_followed_by_public_verification(
        self, payload, apply_details, verify_public_details
    ):
        with mock.patch.dict(
            os.environ, {"FACTORIO_MOD_PORTAL_API_KEY": "test-key"}
        ), mock.patch.object(sys, "argv", ["update_portal_details.py", "--apply"]):
            self.assertEqual(portal_details.main(), 0)

        values = payload.return_value
        apply_details.assert_called_once_with(values, "test-key")
        verify_public_details.assert_called_once_with(values)

    @mock.patch.object(portal_details, "apply_details")
    def test_apply_requires_the_shared_scoped_portal_key(self, apply_details):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            sys, "argv", ["update_portal_details.py", "--apply"]
        ):
            with self.assertRaisesRegex(
                SystemExit, "FACTORIO_MOD_PORTAL_API_KEY is not set"
            ):
                portal_details.main()

        apply_details.assert_not_called()


if __name__ == "__main__":
    unittest.main()
