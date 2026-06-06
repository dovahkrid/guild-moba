#!/usr/bin/env bash
# FAILS if any file under packages/sim/lib imports a platform-bound library or
# uses a non-deterministic API. packages/sim MUST be pure & deterministic.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/packages/sim/lib"

IMPORTS="^[[:space:]]*(import|export)[[:space:]]+['\"](package:flutter/|package:flame|package:web/|dart:ui|dart:io|dart:html|dart:js|dart:ffi|dart:isolate|dart:mirrors)"
# API pattern: match non-comment lines only (comment lines start with optional space then //)
APIS="\bRandom[[:space:]]*\(|\bmath\.(sin|cos|sqrt|pow|atan2|tan)\b|\b(DateTime|Stopwatch)\b"

fail=0
if grep -REn --include='*.dart' "$IMPORTS" "$TARGET"; then fail=1; fi
# For API check, strip pure-comment lines first (lines where first non-space chars are //)
if grep -REn --include='*.dart' "$APIS" "$TARGET" | grep -v '^[^:]*:[0-9]*:[[:space:]]*//' ; then
  # Check if any matches remain after excluding comment lines
  if grep -REn --include='*.dart' "$APIS" "$TARGET" | grep -qv '^[^:]*:[0-9]*:[[:space:]]*//' ; then
    fail=1
  fi
fi
if [ "$fail" -ne 0 ]; then
  echo "FAIL: packages/sim/lib has banned imports or non-deterministic APIs (above)." >&2
  exit 1
fi
echo "PASS: packages/sim/lib is pure and determinism-safe."
