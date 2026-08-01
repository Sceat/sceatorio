#!/usr/bin/env python3
"""Regression tests for byte-safe, retryable Mod Portal publication."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
