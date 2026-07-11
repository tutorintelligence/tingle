#!/usr/bin/env python3
import unittest
from next_version import parse


class NextVersionTests(unittest.TestCase):
    def test_feat_bumps_minor(self):
        self.assertEqual(parse("v1.2.3", "feat: add thing"), "v1.3.0")

    def test_feat_with_scope(self):
        self.assertEqual(parse("v1.2.3", "feat(dictation): vocab"), "v1.3.0")

    def test_fix_bumps_patch(self):
        self.assertEqual(parse("v1.2.3", "fix: stuck icon"), "v1.2.4")

    def test_perf_and_refactor_patch(self):
        self.assertEqual(parse("v0.4.0", "perf: faster goertzel"), "v0.4.1")
        self.assertEqual(parse("v0.4.0", "refactor: tidy config"), "v0.4.1")

    def test_bang_is_major(self):
        self.assertEqual(parse("v1.2.3", "feat!: new protocol"), "v2.0.0")
        self.assertEqual(parse("v1.2.3", "fix(core)!: drop field"), "v2.0.0")

    def test_breaking_change_footer_in_subject(self):
        self.assertEqual(parse("v1.2.3", "feat: x BREAKING CHANGE"), "v2.0.0")

    def test_silent_types_no_release(self):
        for t in ["chore", "docs", "ci", "build", "test", "style"]:
            self.assertIsNone(parse("v1.2.3", f"{t}: whatever"), t)

    def test_non_conventional_no_release(self):
        self.assertIsNone(parse("v1.2.3", "just some text"))

    def test_no_prior_tag_starts_from_zero(self):
        self.assertEqual(parse("", "feat: first"), "v0.1.0")
        self.assertEqual(parse("v0.0.0", "fix: first"), "v0.0.1")

    def test_major_zero_semantics(self):
        # 0.x: feat still bumps minor, breaking bumps to 1.0.0
        self.assertEqual(parse("v0.5.2", "feat: x"), "v0.6.0")
        self.assertEqual(parse("v0.5.2", "feat!: x"), "v1.0.0")


if __name__ == "__main__":
    unittest.main(verbosity=1)
