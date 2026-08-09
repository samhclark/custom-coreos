# ABOUTME: Keeps active documentation authoritative and historical evidence isolated.

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
DOCS = REPO / "docs"
HISTORY = DOCS / "history"
MARKDOWN_LINK = re.compile(r"\[[^]]+\]\(([^)]+)\)")


def active_markdown() -> list[Path]:
    return [
        path
        for path in DOCS.rglob("*.md")
        if HISTORY not in path.parents
    ]


class DocumentationBoundaryTests(unittest.TestCase):
    def test_active_relative_links_resolve(self):
        missing: list[str] = []
        for document in active_markdown():
            for match in MARKDOWN_LINK.finditer(document.read_text()):
                target = match.group(1)
                if target.startswith(("#", "https://", "http://", "mailto:")):
                    continue
                relative_target = target.split("#", 1)[0]
                if relative_target and not (document.parent / relative_target).exists():
                    missing.append(
                        f"{document.relative_to(REPO)} -> {relative_target}"
                    )
        self.assertEqual(missing, [])

    def test_active_docs_do_not_link_to_history(self):
        offenders = [
            str(path.relative_to(REPO))
            for path in active_markdown()
            if re.search(r"\]\([^)]*history/", path.read_text())
        ]
        self.assertEqual(offenders, [])

    def test_archived_evidence_has_an_authority_warning(self):
        archived = sorted((HISTORY / "deployments").glob("*.md"))
        archived += sorted((HISTORY / "migrations").glob("*.md"))

        self.assertTrue(archived)
        for document in archived:
            with self.subTest(document=document.name):
                opening = "\n".join(document.read_text().splitlines()[:8])
                self.assertIn("Archived evidence — not authoritative", opening)

    def test_executable_tools_do_not_live_under_docs(self):
        self.assertEqual(list(DOCS.rglob("*.sh")), [])

    def test_tests_do_not_consume_archived_prose(self):
        offenders = [
            str(path.relative_to(REPO))
            for path in (REPO / "tests").glob("*.py")
            if path != Path(__file__) and "docs/history" in path.read_text()
        ]
        self.assertEqual(offenders, [])

    def test_root_orientation_names_only_active_documentation(self):
        agents = (REPO / "AGENTS.md").read_text()

        self.assertIn("docs/README.md", agents)
        self.assertNotIn("docs/history/", agents)
        self.assertEqual(list(DOCS.glob("plan-*")), [])


if __name__ == "__main__":
    unittest.main()
