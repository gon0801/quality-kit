from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "hooks" / "no_bateria_en_planes.py"


class NoBateriaEnPlanesTests(unittest.TestCase):
    def correr(
        self,
        contenido: str,
        nombre: str = "plans/plan.md",
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            ruta = Path(tmp) / nombre
            ruta.parent.mkdir(parents=True, exist_ok=True)
            ruta.write_text(contenido, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(HOOK), str(ruta)],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_bloque_shell_con_gh_workflow_run_falla(self) -> None:
        r = self.correr("# Plan\n\n```sh\ngh workflow run quality.yml --ref x\n```\n")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("plan.md:4", r.stderr)
        self.assertIn("Regla de David", r.stderr)

    def test_nunca_uses_gh_workflow_run_pasa(self) -> None:
        r = self.correr("Nunca uses gh workflow run: la bateria va en CI.\n")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_bloque_con_pytest_focalizado_pasa(self) -> None:
        r = self.correr("```sh\npytest tests/test_a.py\n```\n")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_bloque_con_pnpm_test_falla(self) -> None:
        r = self.correr("```sh\npnpm test\n```\n")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("plan.md:2", r.stderr)

    def test_frase_con_acento_y_orden_en_prosa_falla(self) -> None:
        r = self.correr("Paso final: corre la batería completa antes del PR.\n")
        self.assertEqual(r.returncode, 1, r.stderr)

    def test_mencion_con_nunca_y_en_ci_en_la_misma_linea_pasa(self) -> None:
        r = self.correr(
            "En local nunca corre la batería completa; la batería completa va en CI.\n"
        )
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_linea_de_codigo_indentada_con_bateria_falla(self) -> None:
        r = self.correr("Pasos:\n\n    pytest -q\n")
        self.assertEqual(r.returncode, 1, r.stderr)

    def test_bloque_no_shell_no_se_revisa_como_comando(self) -> None:
        r = self.correr('```python\ns = "pnpm test"\n```\n')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_comando_entre_comillas_invertidas_falla(self) -> None:
        r = self.correr("Lanza `npx vitest run` para verificar.\n")
        self.assertEqual(r.returncode, 1, r.stderr)

    def test_txt_de_briefs_tambien_se_revisa(self) -> None:
        r = self.correr("```sh\nmake test\n```\n", nombre="briefs/brief.txt")
        self.assertEqual(r.returncode, 1, r.stderr)

    def test_los_candados_del_propio_kit_pasan(self) -> None:
        r = self.correr("```sh\npre-commit run --all-files\n```\n")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_workflow_dispatch_de_la_bateria_falla(self) -> None:
        r = self.correr("Ordena un workflow_dispatch de quality.yml y corre.\n")
        self.assertEqual(r.returncode, 1, r.stderr)

    def test_valla_cuatro_backticks_con_pnpm_test_falla(self) -> None:
        r = self.correr("````sh\npnpm test\n````\n")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("plan.md:2", r.stderr)

    def test_valla_cuatro_tildes_con_pnpm_test_falla(self) -> None:
        r = self.correr("~~~~sh\npnpm test\n~~~~\n")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("plan.md:2", r.stderr)

    def test_cierre_mas_corto_no_cierra_la_valla(self) -> None:
        r = self.correr("````sh\npnpm test\n```\npnpm test\n````\n")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("plan.md:4", r.stderr)

    def test_cierre_mas_largo_si_cierra_la_valla(self) -> None:
        r = self.correr("```sh\npnpm test\n````\n\n```python\npnpm test\n```\n")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("plan.md:2", r.stderr)
        self.assertNotIn("plan.md:6", r.stderr)

    def test_cierre_de_otro_caracter_no_cierra_la_valla(self) -> None:
        r = self.correr("````sh\n~~~\npnpm test\n````\n")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("plan.md:3", r.stderr)

    def test_selectores_incluyen_runbooks(self) -> None:
        for rel in (".pre-commit-config.yaml", "templates/pre-commit-generic.yaml"):
            texto = (ROOT / rel).read_text(encoding="utf-8")
            self.assertIn("runbooks", texto, rel)

    def test_archivo_que_no_es_md_ni_txt_se_ignora(self) -> None:
        r = self.correr("```sh\npnpm test\n```\n", nombre="plans/plan.rst")
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
