#!/usr/bin/env bash
# FAILS if any file under packages/sim/lib, packages/protocol/lib, or
# packages/netcode/lib imports a platform-bound library or uses a
# non-deterministic API. All three packages MUST be pure & deterministic.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMPORTS="^[[:space:]]*(import|export)[[:space:]]+['\"](package:flutter/|package:flame|package:web/|dart:ui|dart:io|dart:html|dart:js|dart:ffi|dart:isolate|dart:mirrors)"
# API pattern: match non-comment lines only (comment lines start with optional space then //)
APIS="\bRandom[[:space:]]*\(|\bmath\.(sin|cos|sqrt|pow|atan2|tan)\b|\b(DateTime|Stopwatch)\b"

fail=0
for TARGET in "$ROOT/packages/sim/lib" "$ROOT/packages/protocol/lib" "$ROOT/packages/netcode/lib"; do
  if grep -REn --include='*.dart' "$IMPORTS" "$TARGET"; then fail=1; fi
  # For API check, strip pure-comment lines first (lines where first non-space chars are //)
  if grep -REn --include='*.dart' "$APIS" "$TARGET" | grep -v '^[^:]*:[0-9]*:[[:space:]]*//' ; then
    # Check if any matches remain after excluding comment lines
    if grep -REn --include='*.dart' "$APIS" "$TARGET" | grep -qv '^[^:]*:[0-9]*:[[:space:]]*//' ; then
      fail=1
    fi
  fi
done
if [ "$fail" -ne 0 ]; then
  echo "FAIL: banned imports or non-deterministic APIs found in one or more packages (above)." >&2
  exit 1
fi
echo "PASS: packages/sim/lib, packages/protocol/lib, and packages/netcode/lib are pure and determinism-safe."
