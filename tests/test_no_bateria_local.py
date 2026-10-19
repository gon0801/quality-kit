from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "hooks" / "no_bateria_local.py"
sys.path.insert(0, str(HOOK.parent))

from no_bateria_local import motivo  # noqa: E402


BLOQUEADOS = [
    "pnpm test",
    "cd ~/dev/wt/r-1004 && pnpm test",
    "pnpm check",
    "pnpm run check:test-types",
    "pnpm tsgo:core",
    "npm test",
    "npm run test",
    "LANG=en_US.UTF-8 pnpm test",
    "node scripts/run-vitest.mjs run",
    "node scripts/run-vitest.mjs run $mios",
    "node scripts/run-vitest.mjs run "
    + " ".join(f"src/a{i}.test.ts" for i in range(7)),
    "npx vitest run",
    "pytest",
    "pytest -q",
    "python3 -m pytest tests/",
    "uv run pytest -q",
    "PYTHONPATH=. pytest -q",
    "python3 -m unittest discover -s tests -p 'test_sistema_agentes_*.py'",
    "python -m unittest",
    "bash scripts/check.sh",
    "make test",
    "ssh gwpc 'cd /d C:\\dev\\goncloud-hermes && python -m unittest discover -s tests'",
    "ssh -o ConnectTimeout=10 gon@100.73.187.5 'cd x && pnpm test'",
    'bash -c "pytest -q"',
    "for f in a b; do pytest; done",
    "echo $(pnpm test)",
    "cat <<'EOF' | bash\npnpm test\nEOF",
    "cat <<EOF | sh\npytest -q\nEOF",
    "cat <<EOF | ssh gwpc\npnpm test\nEOF",
    'echo "$(pnpm test)"',
    'echo "`pytest`"',
    "pytest tests/test_a.py tests/",
    "node scripts/run-vitest.mjs run src/ a.test.ts",
]

PERMITIDOS = [
    "pytest -q tests/test_no_bateria_local.py",
    "python3 -m pytest tests/test_a.py::test_b tests/test_c.py",
    "LANG=en_US.UTF-8 node scripts/run-vitest.mjs run src/gateway/x.test.ts",
    "python3 -m unittest tests.test_no_bateria_local",
    "pnpm install --frozen-lockfile",
    "pnpm build",
    "npm ci",
    "git commit -m 'pnpm test ya no corre en local'",
    'grep -n "pnpm test" docs/plan.md',
    "grep -rn 'pytest -q' tests/",
    "pre-commit run --all-files",
    "python tools/quality_run_python_tests.py pytest",
    "cat > brief.txt <<'EOF'\nCorre pnpm test y pytest -q en CI, no aquí.\nEOF",
    "gh run list -R x --workflow Quality",
    "echo pytest",
    'git commit -q -m "feat: candado\n\npytest sin archivo .py, unittest discover y pnpm test se bloquean"',
    "gh pr create --body 'Bloquea:\npnpm test\npytest -q'",
    "echo 'pytest -q'",
    "python3 - <<'EOF'\nprint('pytest -q')\nEOF",
    "cat > notas.txt <<EOF\npnpm test\nEOF",
    "echo 'pnpm test'",
    "pytest -q tests/test_a.py tests/test_c.py",
]


class MotivoTests(unittest.TestCase):
    def test_baterias_completas_se_bloquean(self) -> None:
        for comando in BLOQUEADOS:
            with self.subTest(comando=comando):
                self.assertIsNotNone(motivo(comando), comando)

    def test_pruebas_focalizadas_y_texto_pasan(self) -> None:
        for comando in PERMITIDOS:
            with self.subTest(comando=comando):
                self.assertIsNone(motivo(comando), comando)

    def test_heredoc_que_alimenta_un_shell_si_se_revisa(self) -> None:
        self.assertIsNotNone(motivo("ssh gwpc bash -s <<'EOF'\npytest -q\nEOF"))


class HookTests(unittest.TestCase):
    def correr(self, evento: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HOOK)],
            input=evento if isinstance(evento, str) else json.dumps(evento),
            capture_output=True,
            text=True,
            check=False,
        )

    def test_bloquea_con_exit_2_y_motivo_en_stderr(self) -> None:
        r = self.correr({"tool_name": "Bash", "tool_input": {"command": "pnpm test"}})
        self.assertEqual(r.returncode, 2)
        self.assertIn("no-bateria-local", r.stderr)

    def test_deja_correr_lo_focalizado(self) -> None:
        r = self.correr(
            {"tool_name": "Bash", "tool_input": {"command": "pytest tests/test_a.py"}}
        )
        self.assertEqual(r.returncode, 0)

    def test_json_ilegible_u_otra_herramienta_no_bloquean(self) -> None:
        self.assertEqual(self.correr("no es json").returncode, 0)
        r = self.correr({"tool_name": "Read", "tool_input": {"file_path": "x"}})
        self.assertEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
