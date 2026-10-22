"""Offline regressions for core.matching."""

from __future__ import annotations

import unittest

from core import matching


class KeywordTests(unittest.TestCase):
    """Keyword matching."""

    def test_words_inside_longer_words_do_not_match(self) -> None:
        """Tea in team and rice in price are not matches."""
        self.assertEqual(matching.find_keywords("team price consolidate improving"), [])


if __name__ == "__main__":
    unittest.main()
