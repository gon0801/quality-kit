#!/usr/bin/env python3
"""Candado PreToolUse (Bash) de Claude Code: ninguna batería completa en local.

Regla de David (2026-10-18): la batería completa corre en CI, una sola vez por
bloque, sobre el SHA final. En la máquina local solo van pruebas focalizadas
con el archivo nombrado. El candado no depende de que el agente se acuerde:
lee el comando antes de que corra y lo bloquea (exit 2) si es una batería.

Entrada: el JSON del hook en stdin ({"tool_name": "Bash", "tool_input":
{"command": ...}}). Salida: exit 0 deja correr; exit 2 bloquea y el motivo va
a stderr, que Claude Code le muestra al agente. Un JSON ilegible deja correr:
el candado no puede tumbar todas las herramientas por un error suyo.
"""

from __future__ import annotations

import json
import re
import shlex
import sys

#: Cuántos archivos de prueba nombrados cuentan como "focalizado".
MAX_ARCHIVOS = 6

MENSAJE = (
    "BLOQUEADO por el candado no-bateria-local (regla de David, 2026-10-18): "
    "la batería completa corre en CI, una vez por bloque, sobre el SHA final. "
    "En local solo pruebas focalizadas con el archivo nombrado (hasta "
    f"{MAX_ARCHIVOS}). Detectado: {{que}}."
)

# Inicio de un comando: principio de línea o tras ; & | ( ` $(, then/do/else,
# o la comilla que abre el comando de un `ssh host '...'` o un `bash -c "..."`
# (una comilla cualquiera no: `grep "pnpm test" f` es texto, no un comando).
# Luego, asignaciones de entorno y envoltorios comunes antes del programa.
_REMOTO = r"(?:ssh(?:\s+-\w+(?:\s+[^\s'\"-]\S*)?)*\s+[^\s'\"-]\S*|(?:bash|sh|zsh|cmd\s+/c|powershell(?:\s+-\w+)*\s+-Command))\s+-?l?c?\s*['\"]"
_INICIO = r"(?:^|[\n;&|(`]|\$\(|\bthen\b|\bdo\b|\belse\b|" + _REMOTO + r")\s*"
_PREFIJOS = r"(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S*|env|command|exec|nice|time|timeout\s+\S+|sudo|-u\s+\S+)\s+)*"


def _comando(nombre: str) -> re.Pattern[str]:
    return re.compile(_INICIO + _PREFIJOS + nombre + r"(?=\s|$|[;&|)'\"`])")


_GESTOR = _comando(r"(?:pnpm|npm|yarn|bun)")
_GESTOR_SCRIPT = re.compile(
    r"^(?:run\s+)?(test|tests|check|lint|tsgo\S*|test:\S+|check:\S+|typecheck)\b"
)
_VITEST = _comando(r"(?:npx\s+|pnpm\s+exec\s+|pnpm\s+)?vitest")
_RUN_VITEST = _comando(r"node\s+(?:\S+\s+)*?scripts/run-vitest\.mjs")
_PYTEST = _comando(
    r"(?:python3?(?:\.\d+)?\s+-m\s+pytest|pytest|py\.test|uv\s+run\s+pytest)"
)
_UNITTEST = _comando(r"python3?(?:\.\d+)?\s+-m\s+unittest")
_SCRIPTS = _comando(
    r"(?:bash\s+|sh\s+)?(?:\./)?(?:scripts/check\.sh|scripts/test-all\S*|make\s+(?:test|check)\b)"
)
_HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
#: Un heredoc solo es un script de shell si alimenta a un shell o a ssh.
_SHELL = re.compile(r"(?:\bssh\b|\b(?:bash|sh|zsh|pwsh|powershell)\b)[^\n]*$")


def _sin_heredocs_de_datos(texto: str) -> str:
    """Quita el cuerpo de los heredocs que no son un script de shell.

    Un brief escrito con `cat > f <<EOF` o un programa de `python3 - <<EOF`
    pueden nombrar baterías como texto o en cadenas; eso no corre en el shell.
    Solo el heredoc que alimenta a bash/sh/zsh/pwsh o a ssh se revisa.
    """
    lineas = texto.split("\n")
    salida: list[str] = []
    i = 0
    while i < len(lineas):
        linea = lineas[i]
        salida.append(linea)
        m = _HEREDOC.search(linea)
        if m and not _SHELL.search(linea[: m.start()]):
            fin = m.group(2)
            i += 1
            while i < len(lineas) and lineas[i].strip() != fin:
                i += 1
            if i < len(lineas):
                salida.append(lineas[i])
        i += 1
    return "\n".join(salida)


_ABRE_REMOTO = re.compile(_REMOTO[: -len(r"['\"]")] + r"$")


def _sin_textos_entrecomillados(texto: str) -> str:
    """Borra el contenido de las cadenas entre comillas que son solo texto.

    Un `git commit -m "..."`, un `gh pr create --body '...'` o un `echo "..."`
    pueden nombrar una batería al principio de una línea sin correr nada. Se
    conservan solo las comillas que abren el comando de un `ssh host '...'` o
    un `bash -c "..."`, que sí corren. Lo borrado se vuelve espacios, sin
    saltos de línea, para que nada adentro parezca el inicio de un comando.
    """
    salida: list[str] = []
    i = 0
    while i < len(texto):
        c = texto[i]
        if c in "'\"" and (i == 0 or texto[i - 1] != "\\"):
            cierre = i + 1
            while cierre < len(texto) and not (
                texto[cierre] == c and (c == "'" or texto[cierre - 1] != "\\")
            ):
                cierre += 1
            if cierre >= len(texto):
                salida.append(texto[i:])
                break
            if _ABRE_REMOTO.search("".join(salida)):
                salida.append(texto[i : cierre + 1])
            else:
                salida.append(c + " " * (cierre - i - 1) + c)
            i = cierre + 1
            continue
        salida.append(c)
        i += 1
    return "".join(salida)


def _argumentos(texto: str, fin: int) -> list[str]:
    """Las palabras que siguen al programa hasta el fin de ese comando."""
    resto = texto[fin:]
    corte = re.search(r"[\n;|&)`]|(?<!\\)['\"]\s*$", resto)
    tramo = resto[: corte.start()] if corte else resto
    try:
        return shlex.split(tramo, comments=False, posix=True)
    except ValueError:
        return tramo.split()


def _archivos(args: list[str], sufijos: tuple[str, ...]) -> tuple[int, bool]:
    """(archivos de prueba nombrados, hay algo que no se puede verificar)."""
    nombrados = 0
    dudoso = False
    for a in args:
        if a.startswith("-"):
            continue
        if "$" in a or "*" in a:
            dudoso = True
            continue
        base = a.split("::", 1)[0]
        if base.endswith(sufijos):
            nombrados += 1
    return nombrados, dudoso


def motivo(comando: str) -> str | None:
    """El motivo del bloqueo, o None si el comando puede correr."""
    texto = _sin_textos_entrecomillados(_sin_heredocs_de_datos(comando))

    for m in _GESTOR.finditer(texto):
        args = _argumentos(texto, m.end())
        if args and _GESTOR_SCRIPT.match(" ".join(args)):
            return f"`{m.group(0).strip(chr(39) + chr(34) + ' ;&|(`')} {' '.join(args[:2])}` (script de batería o chequeo de todo el repo)"

    for patron, sufijos, nombre in (
        (_RUN_VITEST, (".ts", ".tsx", ".mts", ".js", ".mjs"), "run-vitest"),
        (_VITEST, (".ts", ".tsx", ".mts", ".js", ".mjs"), "vitest"),
        (_PYTEST, (".py",), "pytest"),
    ):
        for m in patron.finditer(texto):
            args = _argumentos(texto, m.end())
            nombrados, dudoso = _archivos(args, sufijos)
            if dudoso:
                return f"{nombre} con archivos de una variable o un comodín (no se puede ver cuántos)"
            if nombrados == 0:
                return f"{nombre} sin un archivo de prueba nombrado (correría la suite entera)"
            if nombrados > MAX_ARCHIVOS:
                return f"{nombre} con {nombrados} archivos (más de {MAX_ARCHIVOS} ya es una batería)"

    for m in _UNITTEST.finditer(texto):
        args = _argumentos(texto, m.end())
        if not args or args[0] == "discover" or all(a.startswith("-") for a in args):
            return (
                "unittest discover o sin módulos nombrados (correría la suite entera)"
            )
        if len([a for a in args if not a.startswith("-")]) > MAX_ARCHIVOS:
            return f"unittest con más de {MAX_ARCHIVOS} módulos"

    m = _SCRIPTS.search(texto)
    if m:
        return f"`{m.group(0).strip()}` (corre la batería entera)"
    return None


def main() -> int:
    try:
        evento = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(evento, dict) or evento.get("tool_name") != "Bash":
        return 0
    comando = (evento.get("tool_input") or {}).get("command")
    if not isinstance(comando, str):
        return 0
    que = motivo(comando)
    if que is None:
        return 0
    print(MENSAJE.format(que=que), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
