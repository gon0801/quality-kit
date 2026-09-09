from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
RUNNER_PATH = ROOT / "templates" / "quality-run-python-tests.py"
SPEC = importlib.util.spec_from_file_location("quality_run_python_tests", RUNNER_PATH)
assert SPEC and SPEC.loader
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class PortablePythonRunnerTests(unittest.TestCase):
    def test_uv_lock_prefiere_uv_sin_fijar_python_del_host(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "uv.lock").touch()
            with mock.patch.object(RUNNER.shutil, "which", return_value="/tools/uv"):
                candidates = list(RUNNER._comandos_candidatos(root))

        self.assertEqual(candidates[0], ["/tools/uv", "run", "--frozen", "python"])

    def test_runner_ejecuta_unittest_con_venv_unix(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bin_dir = root / ".venv" / "bin"
            bin_dir.mkdir(parents=True)
            os.symlink(sys.executable, bin_dir / "python")
            (root / "test_sample.py").write_text(
                "import unittest\n"
                "class SampleTest(unittest.TestCase):\n"
                "    def test_ok(self): self.assertEqual(2 + 2, 4)\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER_PATH),
                    "unittest",
                    "discover",
                    "-s",
                    ".",
                    "-p",
                    "test_sample.py",
                    "-q",
                ],
                cwd=root,
                capture_output=True,
                check=False,
                text=True,
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
