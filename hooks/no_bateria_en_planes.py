#!/usr/bin/env python3
"""Candado pre-commit: un plan, brief o runbook no ordena baterias a mano.

Misma regla de David (2026-10-18) del candado no-bateria-local: la bateria
completa corre en CI, una vez por bloque, sobre el SHA final. Estos planes
los va a leer un agente con contexto fresco: si el plan dice "corre pnpm
test" o trae un bloque de shell con la bateria, el agente obedecera y topara
con el candado (o peor, correra la bateria en una maquina sin el). Este
linter lee los .md/.txt que pre-commit le pasa y FALLA con archivo:linea
cuando el documento ordena correr la bateria a mano:

  - "gh workflow run quality.yml" (o cualquier dispatch del workflow),
  - "corre la bateria completa" o "bateria completa local",
  - un comando que no_bateria_local.motivo() bloquearia, cuando aparece como
    instruccion: una linea de codigo indentada, un bloque ``` de shell o un
    span de codigo entre comillas invertidas.

Una linea que explica que NO se hace ("nunca", "no corras", "prohibido",
"en CI") en la misma linea no falla.
"""

from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    import no_bateria_local  # noqa: E402
except ImportError:
    print(
        "no-bateria-en-planes: falta no_bateria_local.py junto a este hook; "
        "reinstala con install-shims.sh",
        file=sys.stderr,
    )
    raise SystemExit(127)

REGLA = (
    "Regla de David (2026-10-18): la bateria completa corre en CI, una vez "
    "por bloque, sobre el SHA final; nunca a mano ni en local."
)

#: Ordenar la bateria con palabras, adentro o afuera de un bloque de codigo.
#: Se aplican sobre la linea normalizada (minusculas y sin acentos).
_FRASES = (
    (
        re.compile(r"gh\s+workflow\s+run\b.*\bquality"),
        "gh workflow run quality.yml (dispatch de la bateria)",
    ),
    (
        re.compile(r"workflow_dispatch\b.*\bquality|\bquality\S*.*workflow_dispatch"),
        "workflow_dispatch de la bateria (quality)",
    ),
    (
        re.compile(
            r"\b(?:corr(?:e|er|es|a|an)|ejecut(?:a|ar|as|en))\s+la\s+bateria\s+completa\b"
        ),
        "corre la bateria completa",
    ),
    (
        re.compile(r"\bbateria\s+completa\s+local\b"),
        "bateria completa local",
    ),
)

#: La misma linea explica que NO se hace a mano: nunca, no corras, no correr,
#: prohibido, en CI, jamas.
_EXENTA = re.compile(
    r"\b(?:nunca|jamas|no\s+corras|no\s+corra|no\s+corran|no\s+correr"
    r"|prohibid[oa]s?|en\s+ci)\b"
)

_VALLA = re.compile(r"^\s*(```|~~~)")
_INFO_SHELL = re.compile(
    r"^(?:sh|bash|shell|zsh|console|terminal|posix|powershell|pwsh|cmd|bat)?\s*$",
    re.I,
)
_PROMPT = re.compile(r"^\s*(?:[$>%#]\s+)")
_SPAN = re.compile(r"`([^`\n]+)`")


def _normaliza(texto: str) -> str:
    """Minusculas y sin acentos, para que 'batería' y 'bateria' valgan igual."""
    descompuesto = unicodedata.normalize("NFD", texto)
    sin_acentos = "".join(c for c in descompuesto if not unicodedata.combining(c))
    return sin_acentos.lower()


def _es_shell(info: str) -> bool:
    """Un bloque ``` (sin lenguaje) o con lenguaje de shell es ejecutable."""
    return bool(_INFO_SHELL.match(info.strip()))


def _codigo_indentado(linea: str) -> bool:
    """Una linea de codigo a lo markdown: 4 espacios o un tab delante."""
    return bool(linea.strip()) and (linea.startswith("    ") or linea.startswith("\t"))


def _violaciones(texto: str) -> list[tuple[int, str]]:
    hallazgos: list[tuple[int, str]] = []
    dentro = False
    shell = False
    for num, linea in enumerate(texto.splitlines(), start=1):
        valla = _VALLA.match(linea)
        if valla:
            dentro = not dentro
            shell = dentro and _es_shell(linea[valla.end() :])
            continue
        normal = _normaliza(linea)
        if _EXENTA.search(normal):
            continue
        for patron, descripcion in _FRASES:
            if patron.search(normal):
                hallazgos.append((num, descripcion))
                break
        linea_codigo: str | None = None
        if shell:
            linea_codigo = _PROMPT.sub("", linea).strip()
        elif not dentro and _codigo_indentado(linea):
            linea_codigo = linea.strip()
        if linea_codigo:
            que = no_bateria_local.motivo(linea_codigo)
            if que is not None:
                hallazgos.append((num, que))
        for span in _SPAN.findall(linea):
            que = no_bateria_local.motivo(span.strip())
            if que is not None:
                hallazgos.append((num, que))
                break
    return hallazgos


def main(argv: list[str]) -> int:
    fallos = 0
    for ruta in argv:
        camino = Path(ruta)
        if camino.suffix.lower() not in (".md", ".txt") or not camino.is_file():
            continue
        try:
            texto = camino.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            print(
                f"no-bateria-en-planes: no pude leer {camino}: {error}",
                file=sys.stderr,
            )
            fallos += 1
            continue
        for num, detalle in _violaciones(texto):
            fallos += 1
            print(
                f"{camino}:{num}: ordena correr la bateria a mano ({detalle}). {REGLA}",
                file=sys.stderr,
            )
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
