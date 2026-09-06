import '../installer.dart';
import '../sim/decision_table.dart';
import '../sim/report.dart';
import '../sim/steering.dart';

/// Renders a [RunReport] as a single self-contained HTML file, so a run's
/// findings survive after the app window closes.
String buildHtmlReport(RunReport report, InstalledPackage package) {
  final design = report.designGroups;
  final engine = report.engineGroups;
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
    ..writeln('<div class="summary ${report.designClean ? 'clean' : 'dirty'}">')
    ..writeln(
      report.designClean
          ? '<strong>No problems found in the dictionary</strong>'
          : '<strong>${design.length} design problem(s) in the dictionary</strong> '
                '(${report.designFindings.length} occurrence(s))',
    )
    ..writeln(
      engine.isEmpty
          ? ''
          : '<div class="stats">${engine.length} engine-integrity problem(s) '
                '-- about the field app, not the dictionary; listed below, '
                'collapsed.</div>',
    )
    ..writeln(
      '<div class="stats">${report.runs} interviews, ${report.records} '
      'records, in ${report.elapsed.inSeconds}s</div>',
    )
    ..writeln('</div>');

  buffer.write(_coverageSection(report));

  if (design.isNotEmpty) {
    buffer.writeln('<h2>Design problems</h2>');
    buffer.writeln(
      '<p class="meta">Each of these is something to change in the data '
      'dictionary and regenerate.</p>',
    );
    buffer.write(_findingsTable(design));
  }
  if (engine.isNotEmpty) {
    buffer.writeln('<details class="engine"><summary><h2>Engine-integrity '
        'problems (${engine.length})</h2></summary>');
    buffer.writeln(
      '<p class="meta">The field app did something wrong with a valid '
      'package: a value stored changed, a key duplicated, a timestamp out of '
      'order. Nothing in the dictionary causes these; they are for whoever '
      'maintains the app.</p>',
    );
    buffer.write(_findingsTable(engine));
    buffer.writeln('</details>');
  }

  buffer.write(_decisionSections(report));
  buffer.write(_steeringSection(report));
  buffer.write(_logicSection(report));

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
        'Displayed and always left blank. Normal for optional questions; '
            'information screens are not listed, since they store nothing.',
        [for (final q in report.neverAnswered.take(50)) _esc(q)],
      ),
    );
  }

  buffer.writeln('</body></html>');
  return buffer.toString();
}

/// The numbers first: what was reached, what was not, how the skips were
/// exercised, which child forms were done. A designer reads this before the
/// problems, because it says how much the problems below are worth.
String _coverageSection(RunReport report) {
  final buffer = StringBuffer()
    ..writeln('<h2>Coverage</h2>')
    ..writeln(
      '<p class="meta">A clean run only means something for the questions it '
      'actually reached. Anything listed here was not tested.</p>',
    )
    ..writeln('<ul class="stat-list">')
    ..writeln(
      '<li>Questions reached: ${report.questionsSeen.length} '
      'of ${report.questionsDeclared.length}</li>',
    )
    ..writeln('<li>Never reached: ${report.neverReached.length}</li>')
    ..writeln(
      '<li>Skip rules exercised both ways: '
      '${report.skipsFired.intersection(report.skipsNotFired).length} '
      'of ${report.skipsDeclared.length} '
      '(always fired ${report.skipsAlwaysFired.length}, never fired '
      '${report.skipsNeverFired.length}, never evaluated '
      '${report.skipsNeverEvaluated.length})</li>',
    )
    ..writeln(
      '<li>Repeat settings exercised: '
      '${report.repeatCells.isEmpty ? 'none' : _esc(report.repeatCells.join(', '))}'
      '</li>',
    );
  for (final entry in report.oneOffs.entries) {
    final t = entry.value;
    buffer.writeln(
      '<li>${_esc(entry.key)} (entered by hand'
      '${t.condition.isEmpty ? '' : ' when ${_esc(t.condition)}'}): '
      '${t.qualified} of ${t.parents} parent(s) qualified, ${t.entered} done</li>',
    );
  }
  if (report.steering.isNotEmpty) {
    buffer.writeln(
      '<li>Steered interviews that did what they set out to: '
      '${report.steering.where((o) => o.achieved).length} of '
      '${report.steering.length}</li>',
    );
  }
  buffer.writeln('</ul>');

  if (report.neverReached.isNotEmpty) {
    buffer.writeln(
      _section(
        'Never reached',
        'No interview ever displayed these. Each is also listed as a '
            'problem below, with the skips that closed the route to it.',
        [for (final q in (report.neverReached.toList()..sort())) _esc(q)],
      ),
    );
  }
  return buffer.toString();
}

String _findingsTable(List<FindingGroup> groups) {
  final buffer = StringBuffer()
    ..writeln('<table class="findings">')
    ..writeln(
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
  return buffer.toString();
}

/// The skip decision tables, one block per form.
///
/// Table A is what a designer checks against the paper questionnaire: after
/// this answer, which question came next. Table B is the inverse: under which
/// answers a gated question was shown or skipped, with the rule the engine
/// reported as responsible. Table C is every question with postskips and how
/// often none of them fired.
String _decisionSections(RunReport report) {
  if (report.decisions.isEmpty) return '';
  final buffer = StringBuffer();
  for (final table in report.decisions.values) {
    if (table.nextAfter.isEmpty && table.postskipOwners.isEmpty) continue;
    buffer.writeln('<details open class="decisions">');
    buffer.writeln(
      '<summary><h2>Skip decisions — ${_esc(table.table)}</h2></summary>',
    );
    buffer.writeln(
      '<p class="meta">Read these against the questionnaire. Counts are '
      'interview-hops: an interview that went back and forward again counts '
      'twice.</p>',
    );

    if (table.nextAfter.isNotEmpty) {
      buffer.writeln('<h3>A. After this answer, the next question shown was</h3>');
      buffer.writeln('<table class="decisions">');
      buffer.writeln(
        '<tr><th>Field</th><th>Answer</th><th>Next question displayed</th>'
        '<th>Hops</th></tr>',
      );
      final fields = table.nextAfter.keys.toList()..sort();
      for (final field in fields) {
        final after = table.nextAfter[field]!;
        for (final value in after.values) {
          final nexts = after.counts[value]!.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          final cls = value == DecisionTableBuilder.blank ? ' class="blank"' : '';
          for (var i = 0; i < nexts.length; i++) {
            buffer.writeln(
              '<tr$cls><td>${i == 0 ? _esc(field) : ''}</td>'
              '<td>${_esc(value)}</td>'
              '<td>${_esc(nexts[i].key)}</td><td>${nexts[i].value}</td></tr>',
            );
          }
        }
      }
      buffer.writeln('</table>');
    }

    final gated = table.gatingWhen.entries
        .where((e) => e.value.values.any((r) => r.skipped > 0 || r.shown == 0))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (gated.isNotEmpty) {
      buffer.writeln('<h3>B. Under which answers each gated question was shown or skipped</h3>');
      buffer.writeln(
        '<p class="meta">The answer columns are what was true at the time -- '
        'context, not cause. The rule column is what the engine reported '
        'firing, and is the cause.</p>',
      );
      buffer.writeln('<table class="decisions">');
      buffer.writeln(
        '<tr><th>Question</th><th>While</th><th>Shown</th><th>Skipped</th>'
        '<th>Skipped by rule</th></tr>',
      );
      for (final entry in gated) {
        final rows = entry.value.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i].value;
          final rules = row.skippedByRule.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          final byRule = rules
              .map((r) => '${_esc(_shortRule(r.key))} ×${r.value}')
              .join('<br>');
          final cls = row.shown > 0 && row.skipped > 0 ? '' : ' class="oneway"';
          buffer.writeln(
            '<tr$cls><td>${i == 0 ? _esc(entry.key) : ''}</td>'
            '<td>${_esc(rows[i].key)}</td><td>${row.shown}</td>'
            '<td>${row.skipped}</td><td>$byRule</td></tr>',
          );
        }
      }
      buffer.writeln('</table>');
    }

    if (table.postskipOwners.isNotEmpty) {
      buffer.writeln('<h3>C. Questions with postskips, and how often none fired</h3>');
      buffer.writeln(
        '<p class="meta">Falling through is normal for an ordinary question. '
        'For an information screen it means the interview continued past '
        'its own ending.</p>',
      );
      buffer.writeln('<table class="decisions">');
      buffer.writeln('<tr><th>Question</th><th>Fell through</th><th></th></tr>');
      final owners = table.postskipOwners.toList()..sort();
      for (final q in owners) {
        final n = table.fallThrough[q] ?? 0;
        final info = table.informationScreens.contains(q);
        final cls = info && n > 0 ? ' class="bad"' : '';
        buffer.writeln(
          '<tr$cls><td>${_esc(q)}</td><td>$n</td>'
          '<td>${info ? 'information screen' : ''}</td></tr>',
        );
      }
      buffer.writeln('</table>');
    }
    buffer.writeln('</details>');
  }
  return buffer.toString();
}

/// `table.owner.kind[n] field op value -> target` without the table.
String _shortRule(String id) {
  final dot = id.indexOf('.');
  return dot < 0 ? id : id.substring(dot + 1);
}

String _steeringSection(RunReport report) {
  if (report.steering.isEmpty) return '';
  final achieved = report.steering.where((o) => o.achieved).length;
  final failed = report.steering.where((o) => !o.achieved).toList();
  final buffer = StringBuffer()
    ..writeln('<details class="steering"><summary><h2>Steered interviews</h2></summary>')
    ..writeln(
      '<p class="meta">One interview per skip rule to make it fire, one to '
      'keep it from firing, and one per question the random interviews '
      'never reached. $achieved of ${report.steering.length} did what they '
      'set out to. The rest are listed; each is also reflected in the '
      'coverage findings above.</p>',
    );
  if (failed.isNotEmpty) {
    buffer.writeln('<table class="decisions">');
    buffer.writeln(
      '<tr><th>Goal</th><th>Subject</th><th>Values chosen</th>'
      '<th>Outcome</th><th>Seed</th></tr>',
    );
    for (final o in failed) {
      buffer.writeln(
        '<tr><td>${_esc(o.plan.purposeLabel)}</td>'
        '<td>${_esc(o.purpose == SteerPurpose.reach ? o.subject : _shortRule(o.subject))}</td>'
        '<td>${_esc(o.plan.describeValues(o.valuesChosen))}</td>'
        '<td>${_esc(o.reason)}</td><td>${o.seed ?? '—'}</td></tr>',
      );
    }
    buffer.writeln('</table>');
  }
  buffer.writeln('</details>');
  return buffer.toString();
}

String _logicSection(RunReport report) {
  if (report.logicChecks.isEmpty) return '';
  final buffer = StringBuffer()
    ..writeln('<details class="logic"><summary><h2>Logic checks</h2></summary>')
    ..writeln(
      '<p class="meta">How often each check was evaluated, how often it '
      'blocked, and how often a field it names was blank at the time -- a '
      'blank operand passes, so a check that only ever saw blanks never '
      'fired for a reason that has nothing to do with the answers.</p>',
    )
    ..writeln('<table class="decisions">')
    ..writeln(
      '<tr><th>Check</th><th>Evaluated</th><th>Blocked</th>'
      '<th>Blank operand</th><th>Blank fields</th></tr>',
    );
  final ids = report.logicChecks.keys.toList()..sort();
  for (final id in ids) {
    final t = report.logicChecks[id]!;
    final blanks = (t.nullFields.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .map((e) => '${_esc(e.key)} ×${e.value}')
        .join(', ');
    final cls = t.evaluated > 0 && t.fired == 0 ? ' class="oneway"' : '';
    buffer.writeln(
      '<tr$cls><td>${_esc(_shortRule(id))}</td><td>${t.evaluated}</td>'
      '<td>${t.fired}</td><td>${t.nullOperand}</td><td>$blanks</td></tr>',
    );
  }
  buffer.writeln('</table></details>');
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
  details > summary { cursor: pointer; list-style: none; }
  details > summary h2 { display: inline-block; }
  details > summary::before { content: '▸ '; color: #666; }
  details[open] > summary::before { content: '▾ '; }
  h3 { margin-top: 20px; font-size: 15px; }
  table.decisions { border-collapse: collapse; font-size: 13px; margin: 6px 0 14px; }
  table.decisions th, table.decisions td { text-align: left; padding: 4px 10px;
    border-bottom: 1px solid #eee; vertical-align: top; }
  table.decisions th { color: #666; font-weight: 600; }
  table.decisions tr.blank td { color: #8a6d00; }
  table.decisions tr.oneway td:nth-child(3), table.decisions tr.oneway td:nth-child(4)
    { font-weight: 600; }
  table.decisions tr.bad td { color: #611a15; background: #fdecea; }
''';
