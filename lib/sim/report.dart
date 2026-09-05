import 'dart:math';

import 'package:datakollecta/models/question.dart';
import 'package:datakollecta/services/survey_loader.dart';

import 'form_runner.dart';
import 'scenario_runner.dart';

/// A finding's [Finding.detail] is a message built for one occurrence: it
/// carries the uniqueid, timestamp, or answered value that happened to be
/// involved, and a save failure's detail is a raw exception dump with the
/// full SQL statement and bound parameters. None of that identifies the
/// *problem* -- the same bug produces a different [Finding.detail] on every
/// run it happens on. These turn a detail into the shape used to decide
/// "is this the same problem", and into a version worth showing a human.
final _causingStatement = RegExp(r'\s*Causing statement:.*', dotAll: true);
final _uuid = RegExp(
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
);
final _quoted = RegExp(r'"[^"]*"');
final _number = RegExp(r'-?\d+(\.\d+)?');

/// Drops the SQL statement and bound parameters a save failure dumps after
/// its message -- useful for grouping and too noisy to show either way.
String _trimmed(String detail) => detail.replaceFirst(_causingStatement, '').trim();

/// [_trimmed], with every value that varies per-record replaced by a
/// placeholder, so the same bug hashes the same regardless of which record
/// tripped over it.
String _signature(String detail) => _trimmed(
  detail,
).replaceAll(_uuid, '<uuid>').replaceAll(_quoted, '"<value>"').replaceAll(_number, '<n>');

/// One thing that is wrong with a package, found by running it.
class Finding {
  const Finding({
    required this.code,
    required this.table,
    required this.detail,
    this.field,
    this.seed,
  });

  final String code;
  final String table;
  final String? field;
  final String detail;
  final int? seed;

  String get where => field == null ? table : '$table.$field';
}

/// Read-me-first order for the report. Everything here is a problem; these
/// differ in how likely a designer is to be able to act on one.
const List<String> _codeOrder = [
  'cannot_advance',
  'question_never_reached',
  'form_never_entered',
  'save_failed',
  'record_missing',
  'duplicate_primary_key',
  'degraded_key',
  'answer_changed',
  'value_never_asked',
  'stoptime_before_starttime',
  'missing_starttime',
  'repeat_livelock',
  'skip_rule_always_fired',
  'skip_rule_never_evaluated',
  'skip_rule_never_fired',
];

int _codeRank(String code) {
  final index = _codeOrder.indexOf(code);
  return index < 0 ? _codeOrder.length : index;
}

/// The same problem, found on more than one run. Reports show one of these
/// per distinct problem rather than repeating it once per occurrence.
class FindingGroup {
  const FindingGroup({
    required this.code,
    required this.table,
    required this.field,
    required this.detail,
    required this.count,
    required this.seeds,
  });

  final String code;
  final String table;
  final String? field;
  final String detail;

  /// How many runs hit this exact problem.
  final int count;

  /// A few of the seeds that hit it, for replay. Not exhaustive.
  final List<int> seeds;

  String get where => field == null ? table : '$table.$field';
}

/// What a run found, in the shape the screens display.
class RunReport {
  RunReport({
    required this.runs,
    required this.records,
    required this.findings,
    required this.questionsDeclared,
    required this.questionsSeen,
    required this.questionsAnswered,
    required this.skipsDeclared,
    required this.skipsFired,
    required this.skipsNotFired,
    required this.blocked,
    required this.unanswerable,
    required this.deadEnds,
    required this.repeatCells,
    required this.elapsed,
  });

  final int runs;
  final int records;
  final List<Finding> findings;

  /// Every question the package declares that an interviewer could be shown
  /// -- `automatic` fields and the end-of-survey screen excluded, since
  /// neither is ever displayed.
  ///
  /// Without this the report could say how many questions were reached but
  /// not which were *not*, which is the reading that finds a form with a hole
  /// in it.
  final Set<String> questionsDeclared;

  /// Every question navigation reached, and every one that got a value. The
  /// difference is questions that were displayed and left blank.
  final Set<String> questionsSeen;
  final Set<String> questionsAnswered;

  /// Every skip rule the package declares.
  final Set<String> skipsDeclared;

  /// Skip rules seen firing, and seen not firing. A rule in neither was never
  /// evaluated at all, which is the reading that matters: a green run whose
  /// branches were never taken proves nothing about them.
  final Set<String> skipsFired;
  final Set<String> skipsNotFired;

  /// Logic checks that refused to let navigation past, with their message.
  final Map<String, int> blocked;

  /// Questions with no selectable option -- a filter that matched nothing.
  final Map<String, int> unanswerable;

  /// Questions where an answer given earlier closed the route, with how many
  /// interviews had to go back. A handful is a respondent meeting a chain of
  /// cross-field checks; a count equal to [runs] is a form nobody can finish.
  final Map<String, int> deadEnds;

  /// `(auto_start_repeat, repeat_enforce_count)` pairs actually exercised.
  final Set<String> repeatCells;

  final Duration elapsed;

  bool get clean => findings.isEmpty;

  /// Questions reached but never given a value on any run.
  Set<String> get neverAnswered => questionsSeen.difference(questionsAnswered);

  /// Questions no interview ever reached. On a run of any size this is the
  /// headline coverage number: a question here was not tested, and if the
  /// route to it does not exist, it never will be.
  Set<String> get neverReached => questionsDeclared.difference(questionsSeen);

  /// Skip rules the engine never even tried. Either the question carrying the
  /// rule was never reached, or an earlier rule in the same cell always
  /// matched first and this one sits behind it.
  Set<String> get skipsNeverEvaluated =>
      skipsDeclared.difference(skipsFired.union(skipsNotFired));

  /// Rules that fired every single time they were tried, and rules that never
  /// fired at all. Only a rule in *both* [skipsFired] and [skipsNotFired] has
  /// actually been exercised as a branch.
  Set<String> get skipsAlwaysFired => skipsFired.difference(skipsNotFired);
  Set<String> get skipsNeverFired => skipsNotFired.difference(skipsFired);

  /// [findings] collapsed to one entry per distinct problem, most-frequent
  /// first, with the run count folded in instead of the finding repeated.
  List<FindingGroup> get groupedFindings {
    final byKey = <String, List<Finding>>{};
    for (final f in findings) {
      final key = '${f.code} ${f.table} ${f.field ?? ''} '
          '${_signature(f.detail)}';
      (byKey[key] ??= []).add(f);
    }
    final groups = [
      for (final entries in byKey.values)
        FindingGroup(
          code: entries.first.code,
          table: entries.first.table,
          field: entries.first.field,
          detail: _trimmed(entries.first.detail),
          count: entries.length,
          seeds: entries.map((f) => f.seed).whereType<int>().toSet().take(5).toList(),
        ),
    ];
    // Most-frequent first within a code, but the codes themselves in the
    // order a designer should read them. Skip-rule coverage is real and worth
    // reporting, and on a form with eighty branches there is a lot of it --
    // enough to bury a question nobody can reach if it sorted by count alone.
    groups.sort((a, b) {
      final rank = _codeRank(a.code).compareTo(_codeRank(b.code));
      return rank != 0 ? rank : b.count.compareTo(a.count);
    });
    return groups;
  }
}

/// Accumulates what a batch of scenarios did.
class ReportBuilder {
  final List<Finding> _findings = [];

  /// What the package *declares*, learned once per form before any run.
  /// Everything else here is what the runs *did*; the report is the
  /// difference between the two.
  final Map<String, Set<String>> _declaredQuestions = {};
  final Map<String, Set<String>> _declaredRules = {};
  final Map<String, String> _ruleTable = {};

  /// Which rules jump over which question, so a never-reached question can
  /// name the rules that closed the route to it. Keyed by field name.
  final Map<String, Set<String>> _rulesJumpingOver = {};

  final Set<String> _formsRun = {};

  /// Forms the harness has no route into. It drives the base form and the
  /// repeat loop; a one-off sister form entered from a menu is neither, so
  /// saying "your form is unreachable" about it would blame the package for
  /// something this app does not do.
  final Set<String> _unreachableForms = {};
  final Set<String> _seen = {};
  final Set<String> _answered = {};
  final Set<String> _fired = {};
  final Set<String> _notFired = {};
  final Map<String, int> _blocked = {};
  final Map<String, int> _unanswerable = {};
  final Map<String, int> _deadEnds = {};
  final Set<String> _cells = {};
  int _runs = 0;
  int _records = 0;
  final Stopwatch _clock = Stopwatch()..start();

  void add(Finding finding) => _findings.add(finding);

  /// Records what one form contains, before any interview runs against it.
  ///
  /// Coverage is a difference, and until this is called the report holds only
  /// one side of it -- which is why a package whose skips make three
  /// questions unreachable used to produce a clean run with a slightly small
  /// "questions reached" number and no finding at all.
  ///
  /// `automatic` questions are excluded because they are computed rather than
  /// displayed, and the end-of-survey screen because navigation stops before
  /// it.
  void declareForm(
    String table,
    List<Question> questions, {
    bool reachable = true,
  }) {
    if (!reachable) _unreachableForms.add(table);
    final fields = _declaredQuestions[table] ??= {};
    final rules = _declaredRules[table] ??= {};

    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      if (q.type != QuestionType.automatic &&
          q.fieldName != SurveyLoader.endOfQuestionsField) {
        fields.add(q.fieldName);
      }

      for (final kind in const ['preskip', 'postskip']) {
        final list = kind == 'preskip' ? q.preSkips : q.postSkips;
        for (var order = 0; order < list.length; order++) {
          final id = FormRunner.skipRuleId(table, q, kind, order);
          rules.add(id);
          _ruleTable[id] = table;

          // A preskip jumps from its own question; a postskip from the one
          // after. Everything in between is a question this rule can close
          // the route to -- which is what lets a never-reached finding name
          // the rules responsible instead of just stating the fact.
          final target = questions.indexWhere(
            (other) => other.fieldName == list[order].skipToFieldName,
          );
          if (target <= i) continue;
          for (var k = kind == 'preskip' ? i : i + 1; k < target; k++) {
            (_rulesJumpingOver[questions[k].fieldName] ??= {}).add(id);
          }
        }
      }
    }
  }

  void observe(Scenario scenario, {required int seed}) {
    _runs++;
    _records += scenario.recordCount;

    for (final run in [scenario.parent, ...scenario.children]) {
      _formsRun.add(run.tableName);
      _seen.addAll(run.route);
      for (final entry in run.storedRow.entries) {
        if (entry.value != null && '${entry.value}'.isNotEmpty) {
          _answered.add(entry.key);
        }
      }
      for (final message in run.blockedBy) {
        _blocked.update(message, (v) => v + 1, ifAbsent: () => 1);
      }
      for (final field in run.unanswerable) {
        _unanswerable.update(field, (v) => v + 1, ifAbsent: () => 1);
      }
      for (final field in run.deadEndRoutes) {
        _deadEnds.update(field, (v) => v + 1, ifAbsent: () => 1);
      }
      for (final field in run.cannotAdvance) {
        _findings.add(
          Finding(
            code: 'cannot_advance',
            table: run.tableName,
            field: field,
            seed: seed,
            detail:
                'no answer got past this question. The app disables Next '
                'until the answer is present, in range and free of logic '
                'errors, so an interviewer here can neither move on nor '
                'finish the interview.',
          ),
        );
      }
      if (run.saveError != null) {
        _findings.add(
          Finding(
            code: 'save_failed',
            table: run.tableName,
            seed: seed,
            detail: run.saveError!,
          ),
        );
      }
    }

    for (final repeat in scenario.repeats) {
      _cells.add('${repeat.autoStartRepeat}/${repeat.enforceMode}');
    }

    if (scenario.livelocked) {
      _findings.add(
        Finding(
          code: 'repeat_livelock',
          table: scenario.parent.tableName,
          seed: seed,
          detail:
              'A repeat loop never terminated. In force mode the loop cannot '
              'be left short, so a child that can never be completed traps the '
              'interviewer.',
        ),
      );
    }
  }

  /// One skip rule, as the engine tried it. Passed straight to
  /// `SkipService.evaluateSkips` via `FormRunner`, so the harness never
  /// re-implements the comparison it is measuring.
  void observeSkip(String rule, bool fired) {
    (fired ? _fired : _notFired).add(rule);
  }

  RunReport build() {
    final declaredQuestions = {
      for (final fields in _declaredQuestions.values) ...fields,
    };
    final declaredRules = {for (final ids in _declaredRules.values) ...ids};

    final report = RunReport(
      runs: _runs,
      records: _records,
      findings: List.unmodifiable([..._findings, ..._coverageFindings()]),
      questionsDeclared: Set.unmodifiable(declaredQuestions),
      questionsSeen: Set.unmodifiable(_seen),
      questionsAnswered: Set.unmodifiable(_answered),
      skipsDeclared: Set.unmodifiable(declaredRules),
      skipsFired: Set.unmodifiable(_fired),
      skipsNotFired: Set.unmodifiable(_notFired),
      blocked: Map.unmodifiable(_blocked),
      unanswerable: Map.unmodifiable(_unanswerable),
      deadEnds: Map.unmodifiable(_deadEnds),
      repeatCells: Set.unmodifiable(_cells),
      elapsed: _clock.elapsed,
    );
    return report;
  }

  /// What the runs did not do.
  ///
  /// These carry no seed: they are properties of the whole batch, not of one
  /// interview, and there is no single run to replay.
  List<Finding> _coverageFindings() {
    if (_runs == 0) return const [];
    final findings = <Finding>[];

    for (final entry in _declaredQuestions.entries) {
      final table = entry.key;
      if (!_formsRun.contains(table)) {
        findings.add(
          Finding(
            code: 'form_never_entered',
            table: table,
            detail: _unreachableForms.contains(table)
                ? 'not tested. This app drives the base form and the repeat '
                      'loop, and this form is entered another way -- so this '
                      'is a gap in the harness, not in the package.'
                : 'no interview ever opened this form, so nothing in it was '
                      'tested. Either its parent never triggered it, or its '
                      'entry condition can never be met.',
          ),
        );
        continue;
      }

      for (final field in entry.value) {
        if (_seen.contains(field)) continue;
        findings.add(
          Finding(
            code: 'question_never_reached',
            table: table,
            field: field,
            detail: 'not reached by any of $_runs interview(s).'
                '${_whyUnreachable(field)}',
          ),
        );
      }
    }

    for (final id in _declaredRules.values.expand((ids) => ids)) {
      final table = _ruleTable[id] ?? '';
      // A form nothing entered already has its own finding, and every rule in
      // it is "never evaluated" as a consequence. Repeating that once per
      // rule buries the one line that explains all of them.
      if (!_formsRun.contains(table)) continue;
      // The id carries its table so rules stay distinct across forms, but
      // `Finding.where` prefixes the table again -- so drop it here rather
      // than printing `hh_info.hh_info.age.preskip[0] ...`.
      final name = id.startsWith('$table.') ? id.substring(table.length + 1) : id;
      final fired = _fired.contains(id);
      final tried = fired || _notFired.contains(id);

      if (!tried) {
        findings.add(
          Finding(
            code: 'skip_rule_never_evaluated',
            table: table,
            field: name,
            detail:
                'never evaluated. Either the question carrying it was never '
                'reached, or an earlier rule in the same cell always matches '
                'first and this one sits behind it.',
          ),
        );
      } else if (fired && !_notFired.contains(id)) {
        findings.add(
          Finding(
            code: 'skip_rule_always_fired',
            table: table,
            field: name,
            detail:
                'fired every time it was evaluated, so the questions it '
                'jumps over were never asked on any route through this rule.',
          ),
        );
      } else if (!fired) {
        findings.add(
          Finding(
            code: 'skip_rule_never_fired',
            table: table,
            field: name,
            detail:
                'evaluated but never true, so the branch it guards was never '
                'taken.',
          ),
        );
      }
    }

    return findings;
  }

  /// The rules that closed the route to [field], when they can be named.
  ///
  /// A question is unreachable because every rule that could jump over it did
  /// so on every route. Saying which ones is the difference between "your
  /// form has a hole" and "here is the pair that made it" -- and it is a join
  /// over data already collected, not a second analysis.
  String _whyUnreachable(String field) {
    final always = (_rulesJumpingOver[field] ?? const <String>{})
        .where((id) => _fired.contains(id) && !_notFired.contains(id))
        .toList()
      ..sort();
    if (always.isEmpty) return '';
    final names = always.map((id) => id.split(' ').first).join(', ');
    return ' Every route to it is closed by a skip that always fired: '
        '$names.';
  }

  /// A stable per-run seed, so any single run can be replayed on its own.
  static int seedFor(int base, int index) =>
      (base * 1000003 + index) & 0x7fffffff;

  static int randomSeed() => Random().nextInt(1 << 30);
}
