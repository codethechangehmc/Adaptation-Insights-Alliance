"""Offline regressions for core.matching."""

from __future__ import annotations

import unittest

from core import matching


class KeywordTests(unittest.TestCase):
    """Keyword matching."""

    def test_whole_words_plurals_and_look_alike_places(self) -> None:
        """Tea in team is no match, farmers matches farmer, Papua New Guinea is not Guinea."""
        self.assertEqual(matching.find_keywords("team price consolidate improving"), [])
        self.assertEqual(matching.find_keywords("support to farmers"), ["farmer"])
        self.assertFalse(matching.is_african("Papua New Guinea"))
        self.assertTrue(matching.is_african("Kenya,Uganda"))


if __name__ == "__main__":
    unittest.main()
