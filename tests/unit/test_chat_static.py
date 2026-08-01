#!/usr/bin/env python3
"""Regression contracts for cross-team chat and research notices."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ResearchNoticeTests(unittest.TestCase):
    def test_base_research_locale_receives_technology_then_team(self) -> None:
        chat = (ROOT / "src/game/chat.lua").read_text(encoding="utf-8")
        handler = chat[
            chat.index("function Chat.on_research_started") : chat.index("return Chat")
        ]

        self.assertIn("local starter = record and record.display_name", handler)
        message = handler[handler.index('"player-started-research"') :]
        self.assertLess(message.index("research.localised_name"), message.index("starter"))
        self.assertNotIn("event.research.force.name,", message)


if __name__ == "__main__":
    unittest.main()
