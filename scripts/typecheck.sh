#!/usr/bin/env sh
# Type checks src/ with luau-lsp. Needs luau-lsp, rojo and Roblox's type
# definitions (globalTypes.None.d.luau from the luau-lsp repository).
#   LUAU_LSP=path/to/luau-lsp ROJO=path/to/rojo DEFS=path/to/globalTypes.d.luau sh scripts/typecheck.sh
set -e
LUAU_LSP=${LUAU_LSP:-luau-lsp}
ROJO=${ROJO:-rojo}
DEFS=${DEFS:-globalTypes.d.luau}
OUT=${TMPDIR:-/tmp}
"$ROJO" sourcemap default.project.json -o "$OUT/corode-sourcemap.json"
"$LUAU_LSP" analyze --definitions="$DEFS" --sourcemap="$OUT/corode-sourcemap.json" src
