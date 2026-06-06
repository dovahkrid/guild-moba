@TestOn('vm')
library;

import 'dart:io';
import 'package:test/test.dart';

/// Patterns banned in the PURE loop layer (apps/server/lib/src/loop).
/// dart:async IS allowed (Match uses StreamSubscription) — not listed here.
/// dart:io, dart:html, flutter, flame, DateTime, Stopwatch, Random,
/// dart:math transcendentals are banned.
final _banned = <RegExp>[
  RegExp(r'''^\s*(import|export)\s+['"]package:flutter/'''),
  RegExp(r'''^\s*(import|export)\s+['"]package:flame'''),
  RegExp(r'''^\s*(import|export)\s+['"]package:web/'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:ui'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:io'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:html'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:js'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:ffi'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:isolate'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:mirrors'''),
  RegExp(r'''^\s*(import|export)\s+['"]dart:math'''),
];

final _bannedApis = <RegExp>[
  RegExp(r'\bRandom\s*\('),
  RegExp(r'\bmath\.(sin|cos|sqrt|pow|atan2|tan)\b'),
  RegExp(r'\b(DateTime|Stopwatch)\b'),
];

/// Find the apps/server root by walking up from [start] until a directory
/// containing both a pubspec.yaml and a lib/ is found.
Directory _findPackageRoot(Directory start) {
  var d = start;
  for (var i = 0; i < 10; i++) {
    if (File('${d.path}/pubspec.yaml').existsSync() &&
        Directory('${d.path}/lib').existsSync()) {
      return d;
    }
    final parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  // Fallback: look for apps/server from cwd
  final cwd = Directory.current;
  final candidate = Directory('${cwd.path}/apps/server');
  if (candidate.existsSync()) return candidate;
  throw StateError('Cannot find apps/server root from ${start.path}');
}

void main() {
  test('apps/server/lib/src/loop is pure: no dart:io, no wall-clock, no RNG', () {
    final packageRoot = _findPackageRoot(Directory.current);
    final loopDir = Directory('${packageRoot.path}/lib/src/loop');
    expect(loopDir.existsSync(), isTrue,
        reason: 'Expected loop dir at ${loopDir.path}');

    final offenders = <String>[];
    for (final f in loopDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      var n = 0;
      for (final line in f.readAsLinesSync()) {
        n++;
        final trimmed = line.trimLeft();
        for (final re in _banned) {
          if (re.hasMatch(line)) offenders.add('${f.path}:$n (import) $line');
        }
        // Skip pure-comment lines for API checks.
        if (trimmed.startsWith('//')) continue;
        for (final re in _bannedApis) {
          if (re.hasMatch(line)) offenders.add('${f.path}:$n (api) $line');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'purity violations in apps/server/lib/src/loop:\n${offenders.join('\n')}');
  });

  test('purity gate bites: detects a dart:io import in a synthetic offender', () {
    // Verify the gate would catch a real violation by scanning a synthetic
    // offending string through the same regexes.
    const offendingLine = "import 'dart:io';";
    final matched = _banned.any((re) => re.hasMatch(offendingLine));
    expect(matched, isTrue,
        reason: 'The purity gate must catch dart:io imports');

    const offendingDatetime = '  final dt = DateTime.now();';
    final matchedApi = _bannedApis.any((re) => re.hasMatch(offendingDatetime));
    expect(matchedApi, isTrue,
        reason: 'The purity gate must catch DateTime usage');
  });
}
