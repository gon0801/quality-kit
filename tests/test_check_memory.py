import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check_memory.py"


class CheckMemoryTests(unittest.TestCase):
    def test_auto_checks_project_memories_without_windows_specific_path(self):
        with tempfile.TemporaryDirectory() as home:
            memory = Path(home) / ".claude/projects/-Users-example/memory"
            memory.mkdir(parents=True)
            (memory / "MEMORY.md").write_text("- [Note](note.md)\n", encoding="utf-8")
            (memory / "note.md").write_text(
                "\n".join(["line"] * 41) + "\n", encoding="utf-8"
            )

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--auto"],
                env={**os.environ, "HOME": home, "USERPROFILE": home},
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("MEMORY-SWEEP:", result.stdout)
            self.assertIn("-Users-example/note.md", result.stdout)
            self.assertIn("1 >40L", result.stdout)

    def test_auto_ignores_wiki_like_text_inside_code(self):
        with tempfile.TemporaryDirectory() as root:
            memory = Path(root) / "memory"
            memory.mkdir()
            (memory / "MEMORY.md").write_text("- [Note](note.md)\n", encoding="utf-8")
            (memory / "note.md").write_text(
                "Inline `[[hooks]]` and `[[:space:]]`.\n```toml\n[[hooks]]\n```\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--auto", "--dir", str(memory)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_auto_missing_explicit_directory_does_not_block_session(self):
        with tempfile.TemporaryDirectory() as root:
            missing = Path(root) / "missing"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--auto", "--dir", str(missing)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("No existe el directorio de memoria", result.stdout)

    def test_auto_ignores_double_backtick_spans(self):
        with tempfile.TemporaryDirectory() as root:
            memory = Path(root) / "memory"
            memory.mkdir()
            (memory / "MEMORY.md").write_text("- [Note](note.md)\n", encoding="utf-8")
            (memory / "note.md").write_text(
                "Example: ``[[hooks]]``\n", encoding="utf-8"
            )

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--auto", "--dir", str(memory)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_auto_keeps_fence_open_after_different_marker(self):
        with tempfile.TemporaryDirectory() as root:
            memory = Path(root) / "memory"
            memory.mkdir()
            (memory / "MEMORY.md").write_text("- [Note](note.md)\n", encoding="utf-8")
            (memory / "note.md").write_text(
                "```md\n~~~\n[[example]]\n```\n", encoding="utf-8"
            )

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--auto", "--dir", str(memory)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_auto_reports_missing_index_target_with_anchor(self):
        with tempfile.TemporaryDirectory() as root:
            memory = Path(root) / "memory"
            memory.mkdir()
            (memory / "MEMORY.md").write_text(
                "- [Missing](missing.md#part)\n", encoding="utf-8"
            )

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--auto", "--dir", str(memory)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("1 links rotos", result.stdout)
            self.assertIn("missing.md", result.stdout)

    def test_index_ignores_code_links_but_finds_real_orphan(self):
        with tempfile.TemporaryDirectory() as root:
            memory = Path(root) / "memory"
            memory.mkdir()
            (memory / "MEMORY.md").write_text(
                "`[Missing](missing.md)`\n```md\n[Note](note.md)\n```\n",
                encoding="utf-8",
            )
            (memory / "note.md").write_text("A real note.\n", encoding="utf-8")

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--auto", "--dir", str(memory)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("1 huérfanos", result.stdout)
            self.assertIn("0 links rotos", result.stdout)

    def test_index_accepts_link_titles(self):
        with tempfile.TemporaryDirectory() as root:
            memory = Path(root) / "memory"
            memory.mkdir()
            (memory / "MEMORY.md").write_text(
                '- [Note](note.md "title")\n', encoding="utf-8"
            )
            (memory / "note.md").write_text("A real note.\n", encoding="utf-8")

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--auto", "--dir", str(memory)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_auto_ignores_multiline_inline_code(self):
        with tempfile.TemporaryDirectory() as root:
            memory = Path(root) / "memory"
            memory.mkdir()
            (memory / "MEMORY.md").write_text("- [Note](note.md)\n", encoding="utf-8")
            (memory / "note.md").write_text(
                "Example: `one\n[[missing]]\ntwo`\n", encoding="utf-8"
            )

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--auto", "--dir", str(memory)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_auto_continues_when_one_project_cannot_be_read(self):
        from contextlib import redirect_stdout
        from io import StringIO
        from unittest.mock import patch

        import check_memory

        with tempfile.TemporaryDirectory() as root:
            first = Path(root) / ".claude/projects/first/memory"
            second = Path(root) / ".claude/projects/second/memory"
            first.mkdir(parents=True)
            second.mkdir(parents=True)
            (second / "MEMORY.md").write_text("- [Note](note.md)\n", encoding="utf-8")
            (second / "note.md").write_text("A real note.\n", encoding="utf-8")
            scan = check_memory.scan_memory

            def scan_with_unreadable_project(path):
                if path == first:
                    raise PermissionError("access denied")
                return scan(path)

            output = StringIO()
            with (
                patch.object(sys, "argv", ["check_memory.py", "--auto"]),
                patch.object(Path, "home", return_value=Path(root)),
                patch.object(
                    check_memory,
                    "scan_memory",
                    side_effect=scan_with_unreadable_project,
                ),
                redirect_stdout(output),
            ):
                result = check_memory.main()

            self.assertEqual(result, 0)
            self.assertIn("first/memory", output.getvalue())
            self.assertNotIn("second/memory", output.getvalue())


if __name__ == "__main__":
    unittest.main()
