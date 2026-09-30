"""Tests for l2_normalize.normalize_slug."""

import unittest

from l2_normalize import normalize_slug


class NormalizeSlugTest(unittest.TestCase):
    def test_empty_string(self):
        self.assertEqual(normalize_slug(""), "")

    def test_whitespace_only(self):
        self.assertEqual(normalize_slug("   \t\n\u3000  "), "")

    def test_whitespace_becomes_single_hyphen(self):
        self.assertEqual(normalize_slug("hello   world"), "hello-world")

    def test_underscores_become_single_hyphen(self):
        self.assertEqual(normalize_slug("hello_world"), "hello-world")
        self.assertEqual(normalize_slug("hello__world"), "hello-world")
        self.assertEqual(normalize_slug("_hello_world_"), "hello-world")

    def test_mixed_whitespace_and_underscores(self):
        self.assertEqual(normalize_slug("hello _ world"), "hello-world")

    def test_consecutive_punctuation_removed(self):
        self.assertEqual(normalize_slug("Hello,,,World!!!"), "helloworld")
        self.assertEqual(normalize_slug("hello ,,, world"), "hello-world")
        self.assertEqual(normalize_slug("a & b"), "a-b")

    def test_ascii_case_lowercased(self):
        self.assertEqual(normalize_slug("Hello World"), "hello-world")
        self.assertEqual(normalize_slug("MiXeD_CaSe"), "mixed-case")

    def test_chinese_characters_preserved(self):
        self.assertEqual(normalize_slug("中文 标签"), "中文-标签")
        self.assertEqual(normalize_slug("Hello 世界"), "hello-世界")

    def test_hyphens_collapsed_and_trimmed(self):
        self.assertEqual(normalize_slug("--Hello---World--"), "hello-world")
        self.assertEqual(normalize_slug("---"), "")

    def test_unicode_trim(self):
        self.assertEqual(normalize_slug("\u00a0hello\u00a0"), "hello")


if __name__ == "__main__":
    unittest.main()
