@TestOn('vm')
library;

import 'dart:io';
import 'package:test/test.dart';

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

/// Find the `packages/protocol` root by walking up from [start] until a directory
/// containing both a `pubspec.yaml` and a `lib/` is found.
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
  // Fallback: look for packages/protocol from cwd
  final cwd = Directory.current;
  final candidate = Directory('${cwd.path}/packages/protocol');
  if (candidate.existsSync()) return candidate;
  throw StateError('Cannot find packages/protocol root from ${start.path}');
}

void main() {
  test('packages/protocol/lib is platform-pure and determinism-safe', () {
    // Resolve lib/ robustly: walk up from cwd until we find a dir with
    // pubspec.yaml + lib/, which is the packages/protocol root.
    final packageRoot = _findPackageRoot(Directory.current);
    final libDir = Directory('${packageRoot.path}/lib');
    final offenders = <String>[];
    for (final f in libDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      var n = 0;
      for (final line in f.readAsLinesSync()) {
        n++;
        final trimmed = line.trimLeft();
        for (final re in _banned) {
          if (re.hasMatch(line)) offenders.add('${f.path}:$n (import) $line');
        }
        // Skip pure-comment lines for API checks (comments may mention banned names
        // as counter-examples, e.g. "dart:math.sqrt is NOT safe here").
        if (trimmed.startsWith('//')) continue;
        for (final re in _bannedApis) {
          if (re.hasMatch(line)) offenders.add('${f.path}:$n (api) $line');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'determinism/purity violations in packages/protocol/lib:\n${offenders.join('\n')}');
  });
}
