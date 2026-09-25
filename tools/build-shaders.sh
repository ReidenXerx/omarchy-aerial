#!/usr/bin/env bash
# Compile the fragment shaders in shell/blur and shell/deco to the .qsb files
# Qt loads. The .qsb files are committed so nothing needs building on
# install; run this after changing a .frag. Needs qsb (qt6-shadertools).
set -euo pipefail
cd "$(dirname "$0")/.."
QSB=${QSB:-/usr/lib/qt6/bin/qsb}
for frag in shell/blur/*.frag shell/deco/*.frag; do
  "$QSB" --glsl "100es,120,150" --hlsl 50 --msl 12 -o "$frag.qsb" "$frag"
  echo "built $frag.qsb"
done
