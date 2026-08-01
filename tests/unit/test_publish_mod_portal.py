#!/usr/bin/env python3
"""Regression tests for byte-safe, retryable Mod Portal publication."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import publish_mod_portal  # noqa: E402


class PortalPublicationIdempotenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.archive = Path(self.temporary.name) / "Sceatorio_2.0.0.zip"
        self.archive.write_bytes(b"test archive")

    def run_main(self) -> int:
        with mock.patch.object(
            sys,
            "argv",
            ["publish_mod_portal.py", str(self.archive)],
        ):
            return publish_mod_portal.main()

    @mock.patch.object(publish_mod_portal, "wait_for_release")
    @mock.patch.object(publish_mod_portal, "upload")
    @mock.patch.object(publish_mod_portal, "public_release")
    @mock.patch.object(publish_mod_portal, "archive_identity")
    def test_identical_existing_release_is_a_successful_no_op(
        self,
        archive_identity: mock.Mock,
        public_release: mock.Mock,
        upload: mock.Mock,
        wait_for_release: mock.Mock,
    ) -> None:
        archive_identity.return_value = ("Sceatorio", "2.0.0", "abc123")
        public_release.return_value = {"version": "2.0.0", "sha1": "abc123"}

        with (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch("builtins.print") as output,
        ):
            self.assertEqual(self.run_main(), 0)

        upload.assert_not_called()
        wait_for_release.assert_not_called()
        output.assert_called_once_with(
            "portal upload: Sceatorio 2.0.0 already matches (abc123)"
        )

    @mock.patch.object(publish_mod_portal, "upload")
    @mock.patch.object(publish_mod_portal, "public_release")
    @mock.patch.object(publish_mod_portal, "archive_identity")
    def test_same_version_with_different_bytes_fails_closed(
        self,
        archive_identity: mock.Mock,
        public_release: mock.Mock,
        upload: mock.Mock,
    ) -> None:
        archive_identity.return_value = ("Sceatorio", "2.0.0", "abc123")
        public_release.return_value = {"version": "2.0.0", "sha1": "different"}

        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(SystemExit, "different SHA-1"):
                self.run_main()

        upload.assert_not_called()

    @mock.patch.object(publish_mod_portal, "wait_for_release")
    @mock.patch.object(publish_mod_portal, "upload")
    @mock.patch.object(publish_mod_portal, "public_release")
    @mock.patch.object(publish_mod_portal, "archive_identity")
    def test_missing_release_uploads_once_then_verifies_public_bytes(
        self,
        archive_identity: mock.Mock,
        public_release: mock.Mock,
        upload: mock.Mock,
        wait_for_release: mock.Mock,
    ) -> None:
        archive_identity.return_value = ("Sceatorio", "2.0.0", "abc123")
        public_release.return_value = None

        with mock.patch.dict(
            os.environ,
            {"FACTORIO_MOD_PORTAL_API_KEY": "scoped-test-key"},
            clear=True,
        ):
            self.assertEqual(self.run_main(), 0)

        upload.assert_called_once_with(
            self.archive.resolve(),
            "Sceatorio",
            "scoped-test-key",
        )
        wait_for_release.assert_called_once_with("Sceatorio", "2.0.0", "abc123")


class PortalPublicationReadbackTests(unittest.TestCase):
    @mock.patch.object(publish_mod_portal, "request_json")
    @mock.patch.object(
        publish_mod_portal.secrets,
        "token_hex",
        side_effect=["first-cache-key", "second-cache-key"],
    )
    def test_public_release_uses_a_fresh_cache_key_for_every_read(
        self, token_hex: mock.Mock, request_json: mock.Mock
    ) -> None:
        request_json.return_value = {
            "releases": [{"version": "2.0.1", "sha1": "abc123"}]
        }

        self.assertEqual(
            publish_mod_portal.public_release("Sceatorio", "2.0.1"),
            {"version": "2.0.1", "sha1": "abc123"},
        )
        self.assertEqual(
            publish_mod_portal.public_release("Sceatorio", "2.0.1"),
            {"version": "2.0.1", "sha1": "abc123"},
        )

        urls = [call.args[0].full_url for call in request_json.call_args_list]
        queries = [
            urllib.parse.parse_qs(urllib.parse.urlsplit(url).query) for url in urls
        ]
        self.assertEqual(
            queries,
            [
                {"verify_release": ["first-cache-key"]},
                {"verify_release": ["second-cache-key"]},
            ],
        )
        self.assertEqual(token_hex.call_count, 2)

    def test_public_visibility_retry_policy_is_bounded_to_about_five_minutes(
        self,
    ) -> None:
        attempts = publish_mod_portal.PUBLIC_VERIFY_ATTEMPTS
        scheduled_wait = sum(
            publish_mod_portal.public_verify_delay(attempt)
            for attempt in range(1, attempts)
        )

        self.assertGreaterEqual(scheduled_wait, 300)
        self.assertLessEqual(scheduled_wait, 360)

    @mock.patch.object(publish_mod_portal.time, "sleep")
    @mock.patch.object(publish_mod_portal, "public_release")
    def test_public_verification_retries_without_sleeping_after_the_last_poll(
        self, public_release: mock.Mock, sleep: mock.Mock
    ) -> None:
        public_release.return_value = None

        with self.assertRaisesRegex(
            SystemExit, "release did not appear in the public API"
        ):
            publish_mod_portal.wait_for_release(
                "Sceatorio", "2.0.1", "abc123", attempts=3
            )

        self.assertEqual(public_release.call_count, 3)
        self.assertEqual(
            sleep.call_args_list,
            [mock.call(2), mock.call(4)],
        )

    @mock.patch.object(publish_mod_portal.time, "sleep")
    @mock.patch.object(publish_mod_portal, "public_release")
    def test_public_verification_fails_immediately_on_a_byte_mismatch(
        self, public_release: mock.Mock, sleep: mock.Mock
    ) -> None:
        public_release.return_value = {"version": "2.0.1", "sha1": "different"}

        with self.assertRaisesRegex(SystemExit, "different SHA-1"):
            publish_mod_portal.wait_for_release(
                "Sceatorio", "2.0.1", "abc123", attempts=3
            )

        public_release.assert_called_once_with("Sceatorio", "2.0.1")
        sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
