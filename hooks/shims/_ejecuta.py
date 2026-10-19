#!/usr/bin/env python3
"""Juez compartido de los shims de quality-kit (candado no-bateria-local).

Cada shim de hooks/shims/ aterriza aqui con el nombre del programa real:
arma el comando "<nombre> <args>" con shlex.join, le pregunta a
no_bateria_local.motivo() y, si hay motivo, imprime el mismo mensaje del
candado en stderr y sale 2. Si no hay motivo, hace exec del programa REAL:
el siguiente en el PATH que no sea el propio directorio de shims, para no
recursar ni aunque el directorio aparezca dos veces en el PATH.

node solo se juzga cuando va a correr vitest (argv[1] termina en
run-vitest.mjs o es vitest); python/python3 solo con -m pytest o -m
unittest. Cualquier otro uso pasa directo: un `node server.js` o un
`python3 script.py` no son baterias.
"""

from __future__ import annotations

import os
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

try:
    import no_bateria_local  # noqa: E402
except ImportError:  # pragma: no cover - instalacion rota, se avisa y se sale
    print(
        "quality-kit shims: falta no_bateria_local.py junto a los shims; "
        "reinstala con install-shims.sh",
        file=sys.stderr,
    )
    raise SystemExit(127)


def _se_juzga(nombre: str, args: list[str]) -> bool:
    """node y python solo pasan por el juez en los usos que corren pruebas."""
    if nombre == "node":
        return bool(args) and (
            args[0] == "vitest" or args[0].endswith("run-vitest.mjs")
        )
    if nombre in ("python", "python3"):
        return any(
            a == "-m" and args[i + 1] in ("pytest", "unittest")
            for i, a in enumerate(args[:-1])
        )
    return True


def _dir_shims() -> Path:
    return Path(__file__).resolve().parent


def _programa_real(nombre: str) -> Path | None:
    """El siguiente <nombre> en el PATH que no vive en el directorio de shims."""
    aqui = _dir_shims()
    candidatos = [f"{nombre}.exe", nombre] if os.name == "nt" else [nombre]
    for entrada in os.environ.get("PATH", "").split(os.pathsep):
        if not entrada:
            continue
        try:
            ruta = Path(entrada).resolve()
        except OSError:  # pragma: no cover - entrada del PATH ilegible
            continue
        if ruta == aqui:
            continue
        for candidato in candidatos:
            programa = ruta / candidato
            if programa.is_file() and os.access(programa, os.X_OK):
                return programa
    return None


def main() -> int:
    if len(sys.argv) < 2:
        print("uso: _ejecuta.py <programa> [args...]", file=sys.stderr)
        return 127
    nombre, args = sys.argv[1], sys.argv[2:]
    if _se_juzga(nombre, args):
        comando = shlex.join([nombre, *args])
        que = no_bateria_local.motivo(comando)
        if que is not None:
            print(no_bateria_local.MENSAJE.format(que=que), file=sys.stderr)
            return 2
    real = _programa_real(nombre)
    if real is None:
        print(
            f"quality-kit shims: no encontre '{nombre}' real fuera de {_dir_shims()}",
            file=sys.stderr,
        )
        return 127
    os.execv(real, [str(real), *args])


if __name__ == "__main__":
    sys.exit(main())
