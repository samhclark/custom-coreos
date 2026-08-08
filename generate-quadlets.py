#!/usr/bin/env python3
"""Compile quadlets/*.toml into the image overlay."""

from pathlib import Path

from quadletgen.cli import main


if __name__ == "__main__":
    raise SystemExit(main(Path(__file__).resolve().parent))
