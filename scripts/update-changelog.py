#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

HEADER = "# Changelog\n\nAll notable changes to this repository will be documented in this file.\n\n"
UNRELEASED = "## [Unreleased]"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Insert a release section into CHANGELOG.md")
    parser.add_argument("--version", required=True, help="Version number without leading v")
    parser.add_argument("--date", required=True, help="Release date in YYYY-MM-DD")
    parser.add_argument("--log-file", required=True, help="Path to a file with bullet-point commit lines")
    parser.add_argument("--changelog", default="CHANGELOG.md", help="Changelog path")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    changelog_path = Path(args.changelog)
    log_path = Path(args.log_file)
    entries = [line.rstrip() for line in log_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not entries:
        return

    release_header = f"## [v{args.version}] - {args.date}"
    release_block = release_header + "\n\n" + "\n".join(entries) + "\n"

    if changelog_path.exists():
        content = changelog_path.read_text(encoding="utf-8")
    else:
        content = HEADER + UNRELEASED + "\n\n"

    if release_header in content:
        raise SystemExit(f"Release section already exists: {release_header}")

    if not content.startswith("# Changelog"):
        content = HEADER + content.lstrip()

    if UNRELEASED not in content:
        if not content.endswith("\n"):
            content += "\n"
        content += "\n" + UNRELEASED + "\n\n"

    before, after = content.split(UNRELEASED, 1)
    after = after.lstrip("\n")
    next_section = after.find("\n## [")
    if next_section == -1:
        remainder = ""
    else:
        remainder = after[next_section + 1 :].lstrip("\n")

    new_content = before + UNRELEASED + "\n\n" + release_block + "\n"
    if remainder:
        new_content += remainder

    if not new_content.endswith("\n"):
        new_content += "\n"

    changelog_path.write_text(new_content, encoding="utf-8")


if __name__ == "__main__":
    main()
