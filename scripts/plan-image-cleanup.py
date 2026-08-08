#!/usr/bin/env python3
# ABOUTME: Plans container-version cleanup from paginated GitHub API JSON.

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import NoReturn


@dataclass(frozen=True, slots=True)
class PackageVersion:
    identifier: int
    created_at: str
    created: datetime
    tags: tuple[str, ...]


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def parse_timestamp(value: object, field: str) -> tuple[str, datetime]:
    if not isinstance(value, str):
        fail(f"{field} must be a timestamp string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"{field} is not an ISO 8601 timestamp: {value!r}")
    if parsed.tzinfo is None:
        fail(f"{field} must include a timezone: {value!r}")
    return value, parsed


def decode_pages(source: str) -> list[object]:
    decoder = json.JSONDecoder()
    offset = 0
    records: list[object] = []
    while offset < len(source):
        while offset < len(source) and source[offset].isspace():
            offset += 1
        if offset == len(source):
            break
        page, offset = decoder.raw_decode(source, offset)
        if not isinstance(page, list):
            fail("each paginated API response must be a JSON array")
        records.extend(page)
    return records


def parse_version(raw: object, index: int) -> PackageVersion:
    field = f"version[{index}]"
    if not isinstance(raw, dict):
        fail(f"{field} must be an object")
    identifier = raw.get("id")
    if isinstance(identifier, bool) or not isinstance(identifier, int):
        fail(f"{field}.id must be an integer")
    created_at, created = parse_timestamp(raw.get("created_at"), f"{field}.created_at")

    metadata = raw.get("metadata", {})
    if not isinstance(metadata, dict):
        fail(f"{field}.metadata must be an object")
    container = metadata.get("container", {})
    if not isinstance(container, dict):
        fail(f"{field}.metadata.container must be an object")
    raw_tags = container.get("tags", [])
    if not isinstance(raw_tags, list) or not all(
        isinstance(tag, str) for tag in raw_tags
    ):
        fail(f"{field}.metadata.container.tags must be an array of strings")
    tags = tuple(sorted(set(raw_tags)))
    return PackageVersion(identifier, created_at, created, tags)


def unique_versions(records: list[object]) -> tuple[PackageVersion, ...]:
    by_identifier: dict[int, PackageVersion] = {}
    for index, raw in enumerate(records):
        version = parse_version(raw, index)
        existing = by_identifier.get(version.identifier)
        if existing is not None and existing != version:
            fail(f"version ID {version.identifier} has conflicting records")
        by_identifier[version.identifier] = version
    return tuple(
        sorted(
            by_identifier.values(),
            key=lambda version: (version.created, version.identifier),
        )
    )


def render_report(
    versions: tuple[PackageVersion, ...],
    cutoff_text: str,
    cutoff: datetime,
) -> tuple[str, tuple[int, ...]]:
    expired = tuple(version for version in versions if version.created < cutoff)
    lines = [
        f"Cutoff: {cutoff_text}",
        f"Total package versions: {len(versions)}",
        f"Versions selected for deletion: {len(expired)}",
        f"Versions retained: {len(versions) - len(expired)}",
    ]
    if expired:
        lines += ["", "Selected versions (oldest first):"]
        for version in expired:
            tags = ",".join(version.tags) if version.tags else "<untagged>"
            lines.append(
                f"  {version.created_at}  ID={version.identifier}  tags={tags}"
            )
    return "\n".join(lines) + "\n", tuple(
        version.identifier for version in expired
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cutoff", required=True)
    parser.add_argument("--github-output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        cutoff_text, cutoff = parse_timestamp(args.cutoff, "cutoff")
        versions = unique_versions(decode_pages(sys.stdin.read()))
        report, expired_ids = render_report(versions, cutoff_text, cutoff)
    except (json.JSONDecodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    sys.stdout.write(report)
    if args.github_output is not None:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write(
                "delete_versions=" + ",".join(map(str, expired_ids)) + "\n"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
