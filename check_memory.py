"""
check_memory.py — sweep del directorio de memoria de Claude Code (reporta, NO borra).

Detecta las tres señales de que la memoria está creciendo como basura:
  1. Archivos > LIMIT_LINES líneas (candidatos a destilar o mover a repo)
  2. Huérfanos: archivos en disco que NO están indexados en MEMORY.md
  3. Links rotos: [[x]] que no resuelven a un archivo, y entradas de MEMORY.md
     que apuntan a archivos inexistentes

Uso:
  python check_memory.py            # reporte de todos los proyectos
  python check_memory.py --auto     # modo hook: silencioso si todo sano;
                                    # imprime <=3 líneas si hay algo que podar
  python check_memory.py --dir <p>  # un directorio de memoria específico

Cableado sugerido como hook SessionStart (sync, timeout 15):
  python check_memory.py --auto
"""

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

LIMIT_LINES = 40


def prose_text(text: str) -> str:
    lines = []
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})(.*)$", line)
        if marker:
            run, rest = marker.groups()
            if fence is None:
                fence = (run[0], len(run))
                continue
            if run[0] == fence[0] and len(run) >= fence[1] and not rest.strip():
                fence = None
                continue
        if fence is None:
            lines.append(line)
    return re.sub(r"(?<!`)(`+)(?!`).*?\1(?!`)", "", "\n".join(lines), flags=re.DOTALL)


@dataclass
class MemoryReport:
    directory: Path
    file_count: int
    words: int
    big: list[tuple[str, int]]
    orphans: list[str]
    broken: list[str]


def scan_memory(mem_dir: Path) -> MemoryReport:
    files = sorted(
        f.name for f in mem_dir.iterdir() if f.is_file() and f.suffix == ".md"
    )
    sizes = {}
    for f in files:
        txt = (mem_dir / f).read_text(encoding="utf-8")
        sizes[f] = (len(txt.splitlines()), len(txt.split()))

    idx_txt = ""
    if (mem_dir / "MEMORY.md").exists():
        idx_txt = (mem_dir / "MEMORY.md").read_text(encoding="utf-8")

    big = [
        (n, sizes[n][0])
        for n in files
        if n != "MEMORY.md" and sizes[n][0] > LIMIT_LINES
    ]
    big.sort(key=lambda x: -x[1])

    index_targets = re.findall(
        r"\]\((?:\./)?([^)#\s]+\.md)(?:#[^\s)]*)?(?:\s+(?:\"[^\"]*\"|'[^']*'))?\)",
        prose_text(idx_txt),
    )
    linked = {os.path.basename(t) for t in index_targets}
    orphans = [n for n in files if n != "MEMORY.md" and n not in linked]

    broken = []
    for n in files:
        txt = (mem_dir / n).read_text(encoding="utf-8")
        for m in re.findall(r"\[\[([^\]\[]+)\]\]", prose_text(txt)):
            if not (mem_dir / (m + ".md")).exists():
                broken.append(f"{n}: [[{m}]]")
    for m in index_targets:
        if not (mem_dir / m).exists():
            broken.append(f"MEMORY.md -> {m}")

    return MemoryReport(
        mem_dir,
        len(files),
        sum(words for _, words in sizes.values()),
        big,
        orphans,
        broken,
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--auto", action="store_true", help="modo hook: silencioso si sano")
    ap.add_argument("--dir", type=Path, help="un directorio de memoria específico")
    args = ap.parse_args()

    if args.dir is not None:
        directories = [args.dir.expanduser()]
    else:
        root = Path.home() / ".claude" / "projects"
        directories = sorted(root.glob("*/memory")) if root.is_dir() else []

    if args.dir is not None and not args.dir.expanduser().is_dir():
        print(f"No existe el directorio de memoria: {args.dir}")
        return 0 if args.auto else 1
    if not directories:
        if not args.auto:
            print("No se encontraron directorios de memoria.")
        return 0

    reports = []
    errors = []
    for directory in directories:
        try:
            reports.append(scan_memory(directory))
        except (OSError, UnicodeError) as exc:
            errors.append(f"{directory}: {exc}")
    big = [
        (r.directory.parent.name, name, lines) for r in reports for name, lines in r.big
    ]
    orphans = [(r.directory.parent.name, name) for r in reports for name in r.orphans]
    broken = [(r.directory.parent.name, name) for r in reports for name in r.broken]
    big.sort(key=lambda item: -item[2])
    problems = len(big) + len(orphans) + len(broken)

    if args.auto:
        if errors:
            print(
                f"MEMORY-SWEEP: {len(errors)} directorios sin leer | primero: {errors[0]}"
            )
        if problems == 0:
            return 0
        line = f"MEMORY-SWEEP: {len(big)} >{LIMIT_LINES}L, {len(orphans)} huérfanos, {len(broken)} links rotos"
        if big:
            line += f" | top: {big[0][0]}/{big[0][1]} {big[0][2]}L"
        if orphans:
            line += f" | huérfano: {orphans[0][0]}/{orphans[0][1]}"
        if broken:
            line += f" | roto: {broken[0][0]}/{broken[0][1]}"
        print(line)
        return 0

    total_words = sum(r.words for r in reports)
    print(
        f"Memoria: {sum(r.file_count for r in reports)} archivos | {total_words} palabras | ~{int(total_words * 1.35)} tokens"
    )
    print(f"  Archivos >{LIMIT_LINES} líneas: {len(big)}")
    for directory, name, lines in big[:10]:
        print(f"    {lines:4d}L  {directory}/{name}")
    print(f"  Huérfanos (no indexados): {len(orphans)}")
    for directory, name in orphans[:10]:
        print(f"    {directory}/{name}")
    print(f"  Links rotos: {len(broken)}")
    for directory, name in broken[:10]:
        print(f"    {directory}/{name}")
    for error in errors:
        print(f"  Error de lectura: {error}")
    return 0 if problems == 0 and not errors else 1


if __name__ == "__main__":
    sys.exit(main())
