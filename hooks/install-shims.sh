#!/bin/sh
# Instala (idempotente) los candados de quality-kit en el directorio del
# usuario: ~/.local/share/quality-kit/candados/. Queda la copia de
# no_bateria_local.py (el candado de Claude Code), no_bateria_en_planes.py
# (el linter de planes) y shims/ (los shims para cualquier CLI de agente).
#
# NO toca el PATH global del usuario: solo imprime la linea de PATH que los
# lanzadores de agentes deben usar para que los shims queden delante de los
# programas reales.
set -eu

src=$(CDPATH= cd "$(dirname "$0")" && pwd)
dest="${HOME}/.local/share/quality-kit/candados"

if [ "$src" != "$dest" ]
then
    mkdir -p "$dest"
    rm -rf "${dest}/shims"
    cp -Rp "${src}/shims" "${dest}/shims"
    for f in "${src}"/*.py "${src}/install-shims.sh"
    do
        [ -f "$f" ] && cp -f "$f" "${dest}/"
    done
fi
chmod +x "${dest}/shims"/* 2>/dev/null || true

echo "Candados de quality-kit instalados en: $dest"
echo "Los lanzadores de agentes deben arrancar con esta linea:"
echo "PATH=\"$dest/shims:\$PATH\""
