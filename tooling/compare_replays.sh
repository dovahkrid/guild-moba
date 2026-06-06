#!/usr/bin/env bash
# Builds & runs tooling/replay_harness.dart on native, dart2js(node),
# dart2wasm(node); FAILS if the three REPLAY_HASH values are not identical.
# Also compares against a committed golden if present.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/tooling"
OUT="$TOOL/build"
FIXTURE="${1:-$TOOL/replay_fixtures/smoke.json}"
mkdir -p "$OUT"

B64="$(base64 -w0 "$FIXTURE" 2>/dev/null || base64 "$FIXTURE" | tr -d '\n')"
DEF="-DFIXTURE_JSON=$B64"

echo "==> [native]"
NATIVE="$(dart run "$DEF" "$TOOL/replay_harness.dart" | grep '^REPLAY_HASH ' | awk '{print $2}')"

echo "==> [js]"
dart compile js -O2 "$DEF" -o "$OUT/replay_harness.js" "$TOOL/replay_harness.dart" >/dev/null
JS="$(node "$OUT/replay_harness.js" | grep '^REPLAY_HASH ' | awk '{print $2}')"

echo "==> [wasm]"
dart compile wasm "$DEF" -o "$OUT/replay_harness.wasm" "$TOOL/replay_harness.dart" >/dev/null
WASM="$(node "$TOOL/wasm_entry.mjs" | grep '^REPLAY_HASH ' | awk '{print $2}')"

printf 'native : %s\njs     : %s\nwasm   : %s\n' "$NATIVE" "$JS" "$WASM"

if [ -z "$NATIVE" ] || [ -z "$JS" ] || [ -z "$WASM" ]; then
  echo "FAIL: a target produced no REPLAY_HASH" >&2; exit 2
fi
if [ "$NATIVE" != "$JS" ] || [ "$JS" != "$WASM" ]; then
  echo "FAIL: determinism divergence across runtimes" >&2; exit 1
fi
echo "PASS: byte-identical across native/js/wasm: $NATIVE"

GOLD="$TOOL/replay_fixtures/$(basename "${FIXTURE%.json}").golden"
if [ -f "$GOLD" ]; then
  if [ "$NATIVE" != "$(cat "$GOLD")" ]; then
    echo "FAIL: hash changed vs golden $GOLD (got $NATIVE)" >&2; exit 3
  fi
  echo "PASS: matches golden $GOLD"
fi
