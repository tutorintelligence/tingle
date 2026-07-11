#!/usr/bin/env python3
"""Compute the next semantic version from the latest tag + a Conventional
Commits subject line.

  feat:            -> minor
  fix: / perf:     -> patch
  refactor:        -> patch
  anything with !  -> major (e.g. "feat!:" or "feat(x)!:")
  BREAKING CHANGE  -> major (in subject; body-scan is the caller's job)
  chore/docs/ci/build/test/style -> no release (prints nothing, exit 0)

Usage: next_version.py <latest_tag> <commit_subject>
  latest_tag: e.g. "v1.4.2" or "" / "v0.0.0" for none yet
Prints the next tag (e.g. "v1.5.0") to stdout, or nothing if no release.
"""
import re
import sys

RELEASING = {"feat": "minor", "fix": "patch", "perf": "patch", "refactor": "patch"}
SILENT = {"chore", "docs", "ci", "build", "test", "style"}


def parse(tag: str, subject: str):
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", tag.strip() or "v0.0.0")
    major, minor, patch = (int(m.group(i)) for i in (1, 2, 3)) if m else (0, 0, 0)

    cc = re.match(r"^(?P<type>[a-zA-Z]+)(\([^)]*\))?(?P<bang>!)?:", subject.strip())
    if not cc:
        return None  # not conventional -> no release (title lint should catch)
    ctype = cc.group("type").lower()
    breaking = bool(cc.group("bang")) or "BREAKING CHANGE" in subject

    if breaking:
        bump = "major"
    elif ctype in RELEASING:
        bump = RELEASING[ctype]
    elif ctype in SILENT:
        return None
    else:
        return None

    if bump == "major":
        major, minor, patch = major + 1, 0, 0
    elif bump == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    return f"v{major}.{minor}.{patch}"


if __name__ == "__main__":
    tag = sys.argv[1] if len(sys.argv) > 1 else ""
    subject = sys.argv[2] if len(sys.argv) > 2 else ""
    result = parse(tag, subject)
    if result:
        print(result)
