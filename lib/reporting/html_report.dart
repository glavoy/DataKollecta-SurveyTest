import '../installer.dart';
import '../sim/report.dart';

/// Renders a [RunReport] as a single self-contained HTML file, so a run's
/// findings survive after the app window closes.
String buildHtmlReport(RunReport report, InstalledPackage package) {
  final groups = report.groupedFindings;
  final generated = DateTime.now();

  final buffer = StringBuffer()
    ..writeln('<!DOCTYPE html>')
    ..writeln('<html lang="en"><head><meta charset="utf-8">')
    ..writeln(
      '<title>Survey Test report — ${_esc(package.surveyName)}</title>',
    )
    ..writeln('<style>$_css</style></head><body>')
    ..writeln('<h1>${_esc(package.surveyName)}</h1>')
    ..writeln(
      '<p class="meta">Package <code>${_esc(package.surveyId)}</code> · '
      'generated ${_esc(generated.toIso8601String())}</p>',
    )
    ..writeln('<div class="summary ${report.clean ? 'clean' : 'dirty'}">')
    ..writeln(
      report.clean
          ? '<strong>No problems found</strong>'
          : '<strong>${groups.length} problem(s) found</strong> '
                '(${report.findings.length} occurrence(s))',
    )
    ..writeln(
      '<div class="stats">${report.runs} interviews, ${report.records} '
      'records, in ${report.elapsed.inSeconds}s</div>',
    )
    ..writeln('</div>');

  if (groups.isNotEmpty) {
    buffer.writeln('<h2>Problems</h2><table class="findings">');
    buffer.writeln(
      '<tr><th>Where</th><th>Code</th><th>Detail</th>'
      '<th>Count</th><th>Replay seeds</th></tr>',
    );
    for (final group in groups) {
      final seeds = group.seeds.isEmpty
          ? '—'
          : group.seeds.join(', ') +
                (group.count > group.seeds.length ? ', …' : '');
      buffer.writeln(
        '<tr><td>${_esc(group.where)}</td><td>${_esc(group.code)}</td>'
        '<td>${_esc(group.detail)}</td><td>${group.count}</td>'
        '<td>${_esc(seeds)}</td></tr>',
      );
    }
    buffer.writeln('</table>');
  }

  buffer.writeln('<h2>Coverage</h2>');
  buffer.writeln(
    '<p class="meta">A clean run only means something for the questions it '
    'actually reached. Anything listed here was not tested.</p>',
  );
  buffer.writeln('<ul class="stat-list">');
  buffer.writeln(
    '<li>Questions reached: ${report.questionsSeen.length} '
    'of ${report.questionsDeclared.length}</li>',
  );
  buffer.writeln(
    '<li>Never reached: ${report.neverReached.length}</li>',
  );
  buffer.writeln(
    '<li>Reached but never answered: ${report.neverAnswered.length}</li>',
  );
  buffer.writeln(
    '<li>Skip rules exercised both ways: '
    '${report.skipsFired.intersection(report.skipsNotFired).length} '
    'of ${report.skipsDeclared.length}</li>',
  );
  buffer.writeln(
    '<li>Repeat settings exercised: '
    '${report.repeatCells.isEmpty ? 'none' : _esc(report.repeatCells.join(', '))}'
    '</li>',
  );
  buffer.writeln('</ul>');

  if (report.neverReached.isNotEmpty) {
    buffer.writeln(
      _section(
        'Never reached',
        'No interview ever displayed these. Each is also listed as a '
            'problem above, with the skips that closed the route to it.',
        [for (final q in (report.neverReached.toList()..sort())) _esc(q)],
      ),
    );
  }

  if (report.skipsDeclared.isNotEmpty) {
    buffer.writeln(
      _section(
        'Skip rules',
        'Only a rule seen both firing and not firing has actually been '
            'tested as a branch.',
        [
          'Exercised both ways: '
              '${report.skipsFired.intersection(report.skipsNotFired).length}',
          'Always fired: ${report.skipsAlwaysFired.length}',
          'Never fired: ${report.skipsNeverFired.length}',
          'Never evaluated: ${report.skipsNeverEvaluated.length}',
        ],
      ),
    );
  }

  if (report.deadEnds.isNotEmpty) {
    final entries = report.deadEnds.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    buffer.writeln(
      _section(
        'Routes that had to go back',
        'An answer given earlier left no valid answer here, so the '
            'interview went back and changed it -- what a person does at a '
            'cross-field check. A count equal to the number of interviews '
            'means nobody can get through.',
        [
          for (final e in entries)
            '${_esc(e.key)} — ${e.value} of ${report.runs} interview(s)',
        ],
      ),
    );
  }

  if (report.unanswerable.isNotEmpty) {
    buffer.writeln(
      _section(
        'Questions with nothing to choose',
        'A csv or database filter matched no rows, so the interviewer '
            'would see an empty list.',
        [
          for (final e in report.unanswerable.entries)
            '${_esc(e.key)} — ${e.value} time(s)',
        ],
      ),
    );
  }

  if (report.blocked.isNotEmpty) {
    final entries = report.blocked.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    buffer.writeln(
      _section(
        'Logic checks that fired',
        'These stop the interviewer moving on. Expected for deliberately '
            'invalid answers; worth reading if a message appears far more '
            'often than the rest.',
        [for (final e in entries.take(30)) '${e.value}× ${_esc(e.key)}'],
      ),
    );
  }

  if (report.neverAnswered.isNotEmpty) {
    buffer.writeln(
      _section(
        'Reached but never answered',
        'Displayed and always left blank. Normal for optional questions '
            'and information screens.',
        [for (final q in report.neverAnswered.take(50)) _esc(q)],
      ),
    );
  }

  buffer.writeln('</body></html>');
  return buffer.toString();
}

String _section(String title, String subtitle, List<String> entries) {
  final buffer = StringBuffer()
    ..writeln('<h2>${_esc(title)}</h2>')
    ..writeln('<p class="meta">${_esc(subtitle)}</p>')
    ..writeln('<ul class="stat-list">');
  for (final entry in entries) {
    buffer.writeln('<li>$entry</li>');
  }
  buffer.writeln('</ul>');
  return buffer.toString();
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

const _css = '''
  body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif;
         color: #1a1a1a; max-width: 900px; margin: 40px auto; padding: 0 20px; }
  h1 { margin-bottom: 4px; }
  h2 { margin-top: 32px; border-bottom: 1px solid #ddd; padding-bottom: 4px; }
  .meta { color: #666; font-size: 13px; }
  .summary { padding: 14px 18px; border-radius: 8px; margin: 16px 0; }
  .summary.clean { background: #e6f4ea; color: #1e4620; }
  .summary.dirty { background: #fdecea; color: #611a15; }
  .stats { margin-top: 6px; font-size: 13px; color: inherit; opacity: 0.85; }
  table.findings { width: 100%; border-collapse: collapse; font-size: 13px; }
  table.findings th, table.findings td { text-align: left; padding: 6px 8px;
    border-bottom: 1px solid #eee; vertical-align: top; }
  table.findings th { color: #666; font-weight: 600; }
  .stat-list { padding-left: 20px; }
  .stat-list li { margin-bottom: 2px; }
  code { background: #f0f0f0; padding: 1px 5px; border-radius: 4px; }
''';
