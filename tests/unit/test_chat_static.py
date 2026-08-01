#!/usr/bin/env python3
"""Regression contracts for cross-team chat and research notices."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ResearchNoticeTests(unittest.TestCase):
    def research_handler(self) -> str:
        chat = (ROOT / "src/game/chat.lua").read_text(encoding="utf-8")
        return chat[
            chat.index("function Chat.on_research_started") : chat.index("return Chat")
        ]

    def test_base_research_locale_receives_technology_then_team(self) -> None:
        handler = self.research_handler()

        self.assertIn("local starter = record and record.display_name", handler)
        message = handler[handler.index('"player-started-research"') :]
        self.assertLess(message.index("research.localised_name"), message.index("starter"))
        self.assertNotIn("event.research.force.name,", message)

    def test_custom_notice_only_targets_other_forces(self) -> None:
        handler = self.research_handler()

        force_filter = "if player.force.index ~= research.force.index then"
        self.assertIn("for _, player in pairs(game.connected_players) do", handler)
        self.assertIn(force_filter, handler)
        self.assertLess(handler.index(force_filter), handler.index("player.print"))


if __name__ == "__main__":
    unittest.main()
