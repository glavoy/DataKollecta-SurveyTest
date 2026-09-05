import 'dart:math';

import 'scenario_runner.dart';

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

/// What a run found, in the shape the screens display.
class RunReport {
  RunReport({
    required this.runs,
    required this.records,
    required this.findings,
    required this.questionsSeen,
    required this.questionsAnswered,
    required this.skipsFired,
    required this.skipsNotFired,
    required this.blocked,
    required this.unanswerable,
    required this.repeatCells,
    required this.elapsed,
  });

  final int runs;
  final int records;
  final List<Finding> findings;

  /// Every question navigation reached, and every one that got a value. The
  /// difference is questions that were displayed and left blank.
  final Set<String> questionsSeen;
  final Set<String> questionsAnswered;

  /// Skip rules seen firing, and seen not firing. A rule in neither was never
  /// evaluated at all, which is the reading that matters: a green run whose
  /// branches were never taken proves nothing about them.
  final Set<String> skipsFired;
  final Set<String> skipsNotFired;

  /// Logic checks that refused to let navigation past, with their message.
  final Map<String, int> blocked;

  /// Questions with no selectable option -- a filter that matched nothing.
  final Map<String, int> unanswerable;

  /// `(auto_start_repeat, repeat_enforce_count)` pairs actually exercised.
  final Set<String> repeatCells;

  final Duration elapsed;

  bool get clean => findings.isEmpty;

  /// Questions reached but never given a value on any run.
  Set<String> get neverAnswered => questionsSeen.difference(questionsAnswered);
}

/// Accumulates what a batch of scenarios did.
class ReportBuilder {
  final List<Finding> _findings = [];
  final Set<String> _seen = {};
  final Set<String> _answered = {};
  final Set<String> _fired = {};
  final Set<String> _notFired = {};
  final Map<String, int> _blocked = {};
  final Map<String, int> _unanswerable = {};
  final Set<String> _cells = {};
  int _runs = 0;
  int _records = 0;
  final Stopwatch _clock = Stopwatch()..start();

  void add(Finding finding) => _findings.add(finding);

  void observe(Scenario scenario, {required int seed}) {
    _runs++;
    _records += scenario.recordCount;

    for (final run in [scenario.parent, ...scenario.children]) {
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

  void observeSkip(String rule, {required bool fired}) {
    (fired ? _fired : _notFired).add(rule);
  }

  RunReport build() => RunReport(
    runs: _runs,
    records: _records,
    findings: List.unmodifiable(_findings),
    questionsSeen: Set.unmodifiable(_seen),
    questionsAnswered: Set.unmodifiable(_answered),
    skipsFired: Set.unmodifiable(_fired),
    skipsNotFired: Set.unmodifiable(_notFired),
    blocked: Map.unmodifiable(_blocked),
    unanswerable: Map.unmodifiable(_unanswerable),
    repeatCells: Set.unmodifiable(_cells),
    elapsed: _clock.elapsed,
  );

  /// A stable per-run seed, so any single run can be replayed on its own.
  static int seedFor(int base, int index) =>
      (base * 1000003 + index) & 0x7fffffff;

  static int randomSeed() => Random().nextInt(1 << 30);
}
