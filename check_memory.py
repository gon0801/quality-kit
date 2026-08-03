#!/usr/bin/env python3
"""
check_memory.py — sweep del directorio de memoria de Claude Code (reporta, NO borra).

Detecta las tres señales de que la memoria está creciendo como basura:
  1. Archivos > LIMIT_LINES líneas (candidatos a destilar o mover a repo)
  2. Huérfanos: archivos en disco que NO están indexados en MEMORY.md
  3. Links rotos: [[x]] que no resuelven a un archivo, y entradas de MEMORY.md
     que apuntan a archivos inexistentes

Uso:
  python check_memory.py            # reporte completo (top 10, totals)
  python check_memory.py --auto     # modo hook: silencioso si todo sano;
                                    # imprime <=3 líneas si hay algo que podar
  python check_memory.py --dir <p>  # otro directorio de memoria (por defecto
                                    # ~/.claude/projects/C--Users-ehven/memory)

Cableado sugerido como hook SessionStart (sync, timeout 15):
  python "C:/Users/ehven/quality-kit/check_memory.py" --auto
"""
import argparse
import os
import re
import sys

LIMIT_LINES = 50


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--auto", action="store_true", help="modo hook: silencioso si sano")
    ap.add_argument("--dir", default=os.path.expanduser(
        "~/.claude/projects/C--Users-ehven/memory"))
    args = ap.parse_args()

    mem_dir = args.dir
    # Corre como hook SessionStart: un directorio ausente (máquina nueva, rename,
    # typo en --dir) hacía que os.listdir tirara un traceback en CADA arranque de
    # sesión. Mismo criterio fail-open que saikit-gate-heal.ps1: en modo hook se
    # calla; en modo reporte lo dice claro y sale con error.
    if not os.path.isdir(mem_dir):
        if args.auto:
            return 0
        print(f"No existe el directorio de memoria: {mem_dir}")
        return 1

    files = sorted(f for f in os.listdir(mem_dir) if f.endswith(".md"))
    if not files:
        return 0

    sizes = {}  # name -> (lines, words)
    for f in files:
        txt = open(os.path.join(mem_dir, f), encoding="utf-8").read()
        # splitlines() y no count("\n")+1: este último cuenta una línea de más en
        # todo archivo que termina con newline (casi todos), corriendo el umbral.
        sizes[f] = (len(txt.splitlines()), len(txt.split()))

    idx_txt = ""
    if os.path.exists(os.path.join(mem_dir, "MEMORY.md")):
        idx_txt = open(os.path.join(mem_dir, "MEMORY.md"), encoding="utf-8").read()

    # 1. Archivos que crecieron (MEMORY.md es el índice, se permite más largo)
    big = [(n, sizes[n][0]) for n in files if n != "MEMORY.md" and sizes[n][0] > LIMIT_LINES]
    big.sort(key=lambda x: -x[1])

    # 2. Huérfanos: en disco, no linkeados en MEMORY.md.
    # El substring `](nombre.md)` daba falsos huérfanos en cuanto el link traía
    # ancla `](x.md#seccion)` o ruta relativa `](./x.md)`. Se extraen los destinos
    # y se comparan por nombre, tolerando ambas formas.
    linked = set(re.findall(r"\]\((?:\./)?([^)#\s]+\.md)", idx_txt))
    linked = {os.path.basename(t) for t in linked}
    orphans = [n for n in files if n != "MEMORY.md" and n not in linked]

    # 3. Links rotos: [[x]] sin archivo, y MEMORY.md -> archivo inexistente
    broken = []
    for n in files:
        txt = open(os.path.join(mem_dir, n), encoding="utf-8").read()
        # El regex viejo `[a-z0-9\-]+` dejaba SIN CHEQUEAR todo link con
        # mayúsculas, guion bajo, ':' o extensión — justo los malformados que hay
        # que cazar. Y volvía inalcanzable la excepción hardcodeada que lo
        # acompañaba (contenía ':', que el propio regex nunca podía capturar), por
        # eso se elimina: era código muerto sin ninguna referencia viva.
        for m in re.findall(r"\[\[([^\]\[]+)\]\]", txt):
            if not os.path.exists(os.path.join(mem_dir, m + ".md")):
                broken.append(f"{n}: [[{m}]]")
    for m in re.findall(r"\]\(([^)]+\.md)\)", idx_txt):
        if not os.path.exists(os.path.join(mem_dir, m)):
            broken.append(f"MEMORY.md -> {m}")

    problems = len(big) + len(orphans) + len(broken)

    if args.auto:
        if problems == 0:
            return 0  # sano: sin output, no agrega contexto
        line = f"MEMORY-SWEEP: {len(big)} >{LIMIT_LINES}L, {len(orphans)} huérfanos, {len(broken)} links rotos"
        if big:
            line += f" | top: {big[0][0]} {big[0][1]}L"
        if orphans:
            line += f" | huérfano: {orphans[0]}"
        if broken:
            line += f" | roto: {broken[0]}"
        print(line)
        return 0

    # Modo reporte completo
    total_words = sum(sizes[n][1] for n in files)
    print(f"Memoria: {len(files)} archivos | {total_words} palabras | ~{int(total_words*1.35)} tokens")
    print(f"  Archivos >{LIMIT_LINES} líneas: {len(big)}")
    for n, l in big[:10]:
        print(f"    {l:4d}L  {n}")
    print(f"  Huérfanos (no indexados): {len(orphans)}")
    for n in orphans[:10]:
        print(f"    {n}")
    print(f"  Links rotos: {len(broken)}")
    for b in broken[:10]:
        print(f"    {b}")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
