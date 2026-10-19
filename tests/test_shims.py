from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHIMS = ROOT / "hooks" / "shims"

#: Un programa falso "real": escribe sus argumentos en el marcador y sale 0.
FAKE = '#!/bin/sh\nprintf \'%s\\n\' "$@" >> "$MARKER_FILE"\n'

# python3 no va aqui: el falso python3 debe poder ejecutar _ejecuta.py, asi
# que es un enlace al python real con el que corren estas pruebas.
FALSOS = ("pytest", "python", "node", "pnpm", "npm", "npx", "make")


@unittest.skipIf(
    os.name == "nt",
    "los shims son ejecutables POSIX (#!/bin/sh); en Windows el candado de "
    "la bateria vive en el hook de Claude Code, no en el PATH",
)
class ShimsTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name)
        self.fakebin = base / "fakebin"
        self.fakebin.mkdir()
        self.marker = base / "marcador.txt"
        for nombre in FALSOS:
            falso = self.fakebin / nombre
            falso.write_text(FAKE, encoding="utf-8")
            falso.chmod(0o755)
        (self.fakebin / "python3").symlink_to(Path(sys.executable).resolve())

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def correr(
        self,
        nombre: str,
        *args: str,
        duplicado: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        shims = str(SHIMS)
        path = ":".join([shims] * (2 if duplicado else 1) + [str(self.fakebin)])
        env = {**os.environ, "PATH": path, "MARKER_FILE": str(self.marker)}
        self.marker.unlink(missing_ok=True)
        return subprocess.run(
            [str(SHIMS / nombre), *args],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    def test_pytest_sin_archivo_bloquea_y_el_real_no_corre(self) -> None:
        r = self.correr("pytest", "-q")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("no-bateria-local", r.stderr)
        self.assertFalse(self.marker.exists(), "el pytest real no debio correr")

    def test_pytest_con_archivo_corre_el_real_con_los_mismos_args(self) -> None:
        r = self.correr("pytest", "tests/test_a.py")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.marker.read_text().splitlines(), ["tests/test_a.py"])

    def test_python3_con_c_pasa_directo(self) -> None:
        r = self.correr("python3", "-c", "print(1)")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1", r.stdout)

    def test_python3_unittest_discover_bloquea(self) -> None:
        r = self.correr("python3", "-m", "unittest", "discover")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertFalse(self.marker.exists(), "el unittest real no debio correr")

    def test_node_con_otro_script_pasa_directo(self) -> None:
        r = self.correr("node", "otro.js")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.marker.read_text().splitlines(), ["otro.js"])

    def test_node_con_run_vitest_bloquea(self) -> None:
        r = self.correr("node", "scripts/run-vitest.mjs", "run")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertFalse(self.marker.exists(), "el node real no debio correr")

    def test_sin_recursion_aun_con_el_dir_de_shims_dos_veces_en_el_path(self) -> None:
        r = self.correr("pytest", "tests/test_a.py", duplicado=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.marker.read_text().splitlines(), ["tests/test_a.py"])

    def test_gestores_make_y_python_variants(self) -> None:
        bloquean = (
            ("pnpm", "test"),
            ("npm", "run", "test"),
            ("npx", "vitest", "run"),
            ("make", "test"),
            ("python", "-m", "pytest", "-q"),
        )
        for caso in bloquean:
            with self.subTest(caso=caso):
                r = self.correr(*caso)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertFalse(self.marker.exists())
        pasan = (
            ("pnpm", "install"),
            ("npm", "ci"),
            ("npx", "jest"),
            ("make", "build"),
            ("python", "--version"),
        )
        for caso in pasan:
            with self.subTest(caso=caso):
                r = self.correr(*caso)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertTrue(self.marker.exists(), f"el real no corrio: {caso}")

    def test_install_shims_es_idempotente_e_imprime_la_linea_de_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            env = {**os.environ, "HOME": str(home)}
            esperado = f'PATH="{home}/.local/share/quality-kit/candados/shims:$PATH"'
            for _ in range(2):
                r = subprocess.run(
                    ["sh", str(ROOT / "hooks" / "install-shims.sh")],
                    capture_output=True,
                    text=True,
                    env=env,
                    check=False,
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(esperado, r.stdout)
            candados = home / ".local" / "share" / "quality-kit" / "candados"
            self.assertTrue((candados / "no_bateria_local.py").is_file())
            self.assertTrue((candados / "no_bateria_en_planes.py").is_file())
            shim = candados / "shims" / "pytest"
            self.assertTrue(shim.is_file() and os.access(shim, os.X_OK))


if __name__ == "__main__":
    unittest.main()
