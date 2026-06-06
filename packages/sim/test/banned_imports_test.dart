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
];

final _bannedApis = <RegExp>[
  RegExp(r'\bRandom\s*\('),
  RegExp(r'\bmath\.(sin|cos|sqrt|pow|atan2|tan)\b'),
  RegExp(r'\b(DateTime|Stopwatch)\b'),
];

void main() {
  test('packages/sim/lib is platform-pure and determinism-safe', () {
    final libDir = Directory('lib');
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
        reason: 'determinism/purity violations in packages/sim/lib:\n${offenders.join('\n')}');
  });
}
