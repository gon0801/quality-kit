from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class MacosPortabilityTests(unittest.TestCase):
    def test_nested_powershell_uses_current_runtime(self) -> None:
        for relative in ("init-repo.ps1", "heal-repo.ps1", "new-repo.ps1"):
            source = (ROOT / relative).read_text(encoding="utf-8")
            self.assertNotRegex(source, r"(?m)^\s*&\s+powershell\b", relative)
            self.assertIn("Get-CurrentPowerShellExe", source, relative)

    def test_user_configuration_uses_portable_home(self) -> None:
        for relative in (
            "install-ai-rules.ps1",
            "uninstall-ai-rules.ps1",
            "install-docs-groom.ps1",
            "uninstall-docs-groom.ps1",
            "saikit-gate-heal.ps1",
        ):
            source = (ROOT / relative).read_text(encoding="utf-8")
            self.assertNotIn("$env:USERPROFILE", source, relative)
            self.assertIn("SpecialFolder]::UserProfile", source, relative)

    def test_test_harness_uses_current_runtime_and_platform_path_separator(
        self,
    ) -> None:
        source = (ROOT / "tests/run-tests.ps1").read_text(encoding="utf-8")
        self.assertNotIn("$psi.FileName = 'powershell'", source)
        self.assertIn("Get-CurrentPowerShellExe", source)
        self.assertIn("[System.IO.Path]::PathSeparator", source)
        self.assertIn("'PATH'", source)
        self.assertNotIn(r"C:\dev\summonaikit-claude", source)

    def test_ci_runs_on_windows_and_macos(self) -> None:
        source = (ROOT / ".github/workflows/quality.yml").read_text(encoding="utf-8")
        self.assertIn("matrix.os", source)
        self.assertIn("windows-latest", source)
        self.assertIn("macos-latest", source)

    @unittest.skipUnless(sys.platform == "darwin", "prueba especifica de macOS")
    def test_init_repo_invokes_policy_with_current_pwsh(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            repo = Path(raw_dir) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "remote",
                    "add",
                    "origin",
                    "https://github.com/example/portable-probe.git",
                ],
                check=True,
            )
            result = subprocess.run(
                [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(ROOT / "init-repo.ps1"),
                    "-RepoPath",
                    str(repo),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            policy = repo / ".claude-code-harness.config.yaml"
            self.assertIn(
                "protected_branch_push: allow", policy.read_text(encoding="utf-8")
            )

    @unittest.skipUnless(sys.platform == "darwin", "prueba especifica de macOS")
    def test_global_rules_use_portable_home_override(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            fake_home = Path(raw_dir)
            env = os.environ.copy()
            env["QUALITY_KIT_USER_HOME"] = str(fake_home)
            result = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(ROOT / "install-ai-rules.ps1")],
                env=env,
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            codex_rules = fake_home / ".codex" / "AGENTS.md"
            content = codex_rules.read_text(encoding="utf-8")
            self.assertIn(str(ROOT / "init-repo.ps1"), content)


if __name__ == "__main__":
    unittest.main()
