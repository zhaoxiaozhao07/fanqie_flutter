#!/usr/bin/env python3
"""Read the one release identity from committed pubspec, never an override."""
import argparse
from dataclasses import dataclass
from pathlib import Path
import re

SEMVER = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


@dataclass(frozen=True)
class ReleaseIdentity:
    version: str
    build: str

    @property
    def full_version(self):
        return f"{self.version}+{self.build}"

    @property
    def tag(self):
        return f"v{self.version}"


def read_identity(pubspec):
    lines = [
        line for line in Path(pubspec).read_text(encoding="utf-8").splitlines()
        if line.startswith("version:")
    ]
    if len(lines) != 1:
        raise ValueError("Expected exactly one pubspec version")
    match = re.fullmatch(rf"version:\s*({SEMVER})\+([1-9][0-9]*)\s*", lines[0])
    if not match:
        raise ValueError("Expected version: semver+positive-build in pubspec")
    return ReleaseIdentity(*match.groups())


def repository_identity():
    return read_identity(Path(__file__).resolve().parents[1] / "pubspec.yaml")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pubspec", type=Path)
    args = parser.parse_args()
    print(read_identity(args.pubspec).full_version)
