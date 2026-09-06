import 'dart:math';

import 'package:datakollecta/models/question.dart';

import 'decision_table.dart';
import 'logic_tally.dart';
import 'scenario_runner.dart';
import 'skip_topology.dart';
import 'steering.dart';

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
  FindingTier get tier => tierOf(code);
}

/// Who a finding is for.
///
/// A *design* finding is about the dictionary: a question nobody can reach,
/// a skip that routes Don't know the wrong way, a csv that leaves a list
/// empty. The designer fixes it in Excel and regenerates. An *engine* finding
/// is about the field app doing something wrong with a valid package: an
/// answer stored changed, a duplicate key, a timestamp out of order. Nothing
/// in the dictionary causes those, and the designer cannot fix them -- they
/// are for whoever maintains the app, and they exist here because this is the
/// only place the real save and repeat path runs outside a widget.
enum FindingTier { design, engine }

const Set<String> _engineCodes = {
  'save_failed',
  'record_missing',
  'duplicate_primary_key',
  'degraded_key',
  'answer_changed',
  'value_never_asked',
  'stoptime_before_starttime',
  'missing_starttime',
  'repeat_livelock',
  'child_link_missing',
};

FindingTier tierOf(String code) =>
    _engineCodes.contains(code) ? FindingTier.engine : FindingTier.design;

/// Read-me-first order for the report. Everything here is a problem; these
/// differ in how likely a designer is to be able to act on one. Design
/// findings first, most actionable first; then the engine tier.
const List<String> _codeOrder = [
  // The dictionary is wrong.
  'cannot_advance',
  'question_never_reached',
  'form_never_entered',
  'information_screen_fell_through',
  'skip_domain_gap',
  'special_code_routed_as_value',
  'skip_dropped_by_parser',
  'logic_check_malformed',
  'logic_check_inert',
  'csv_file_missing',
  'csv_empty',
  'csv_cascade_empty',
  'unanswerable',
  'skip_rule_always_fired',
  'skip_rule_never_evaluated',
  'skip_rule_never_fired',
  // The engine did something wrong with a valid package.
  'save_failed',
  'record_missing',
  'duplicate_primary_key',
  'degraded_key',
  'answer_changed',
  'value_never_asked',
  'stoptime_before_starttime',
  'missing_starttime',
  'repeat_livelock',
  'child_link_missing',
];

/// Codes whose findings describe the whole batch rather than one interview,
/// and so carry no seed to replay: nothing a single run did produced them.
const Set<String> _batchLevelCodes = {
  'question_never_reached',
  'form_never_entered',
  'information_screen_fell_through',
  'skip_rule_always_fired',
  'skip_rule_never_evaluated',
  'skip_rule_never_fired',
  'logic_check_inert',
  'skip_domain_gap',
  'special_code_routed_as_value',
  'skip_dropped_by_parser',
  'logic_check_malformed',
  'csv_file_missing',
  'csv_empty',
  'csv_cascade_empty',
};

bool isBatchLevel(String code) => _batchLevelCodes.contains(code);

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
  FindingTier get tier => tierOf(code);
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
    required this.steering,
    required this.decisions,
    required this.logicChecks,
    required this.oneOffs,
    required this.informationQuestions,
    required this.elapsed,
  });

  final int runs;
  final int records;
  final List<Finding> findings;

  /// Every steered interview, and whether it proved what it set out to.
  final List<SteeringOutcome> steering;

  /// Per form: where each answer led, and what each question was shown or
  /// skipped under. The tables a designer reads against the questionnaire.
  final Map<String, SkipDecisionTable> decisions;

  /// Every declared logic check -> what the interviews did with it.
  final Map<String, LogicTally> logicChecks;

  /// Manually-entered child forms -> how many parents qualified and were
  /// followed up.
  final Map<String, OneOffTally> oneOffs;

  /// `information` screens across every form. They display text and store
  /// nothing, so "reached but never answered" is their normal state and a
  /// postskip that always fires on one is the design, not a gap.
  final Set<String> informationQuestions;

  /// Checks evaluated at least once that never blocked anybody. Not a
  /// finding: a random respondent rarely trips a cross-field check.
  Set<String> get logicNeverFired => {
        for (final e in logicChecks.entries)
          if (e.value.evaluated > 0 && e.value.fired == 0) e.key,
      };

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

  /// No design finding: the dictionary itself came through clean. Engine
  /// findings may still be present; they are somebody else's to fix.
  bool get designClean => designFindings.isEmpty;

  List<Finding> get designFindings =>
      [for (final f in findings) if (f.tier == FindingTier.design) f];
  List<Finding> get engineFindings =>
      [for (final f in findings) if (f.tier == FindingTier.engine) f];

  List<FindingGroup> get designGroups =>
      [for (final g in groupedFindings) if (g.tier == FindingTier.design) g];
  List<FindingGroup> get engineGroups =>
      [for (final g in groupedFindings) if (g.tier == FindingTier.engine) g];

  /// Questions reached but never given a value on any run. Information
  /// screens are excluded: they have no value to give.
  Set<String> get neverAnswered =>
      questionsSeen.difference(questionsAnswered).difference(informationQuestions);

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
      final tier = a.tier.index.compareTo(b.tier.index);
      if (tier != 0) return tier;
      final rank = _codeRank(a.code).compareTo(_codeRank(b.code));
      return rank != 0 ? rank : b.count.compareTo(a.count);
    });
    return groups;
  }
}

/// How often a manually-entered child form was called for, and done.
class OneOffTally {
  OneOffTally(this.condition);
  final String condition;
  int parents = 0;
  int qualified = 0;
  int entered = 0;
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

  /// The skip structure of every declared form, by table.
  final Map<String, SkipTopology> _topologies = {};
  final Map<String, DecisionTableBuilder> _decisions = {};
  final Map<String, LogicTally> _logic = {};
  final Map<String, String> _logicTable = {};
  final Map<String, OneOffTally> _oneOffs = {};

  /// Which rules jump over which question, so a never-reached question can
  /// name the rules that closed the route to it. Keyed by field name.
  final Map<String, Set<String>> _rulesJumpingOver = {};

  SkipTopology? topologyOf(String table) => _topologies[table];

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
  final List<SteeringOutcome> _steering = [];
  int _runs = 0;
  int _records = 0;
  final Stopwatch _clock = Stopwatch()..start();

  void add(Finding finding) => _findings.add(finding);

  bool wasSeen(String field) => _seen.contains(field);

  void observeSteering(SteeringOutcome outcome) => _steering.add(outcome);

  /// The steered attempts at [subject] with [purpose], if any ran.
  Iterable<SteeringOutcome> _steeringFor(String subject, SteerPurpose purpose) =>
      _steering.where((o) => o.subject == subject && o.purpose == purpose);

  /// How a steered attempt failed, phrased for a finding; empty when no
  /// attempt was made.
  String _steeringNote(String subject, SteerPurpose purpose) {
    final attempts = _steeringFor(subject, purpose).toList();
    if (attempts.isEmpty) return '';
    final infeasible = attempts.where((a) => a.seed == null).toList();
    if (infeasible.isNotEmpty) {
      return ' Steering could not even try: ${infeasible.first.reason}.';
    }
    final tried = attempts
        .map((a) => a.plan.describeValues(a.valuesChosen))
        .where((s) => s.isNotEmpty)
        .toSet()
        .join(' / ');
    final reason = attempts.map((a) => a.reason).where((r) => r.isNotEmpty).toSet().join('; ');
    return ' A steered interview tried ${tried.isEmpty ? 'the obvious answers' : tried}'
        '${reason.isEmpty ? '' : ' and $reason'}.';
  }

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
    final topology = SkipTopology.of(table, questions);
    _topologies[table] = topology;
    _decisions[table] = DecisionTableBuilder(topology);

    (_declaredQuestions[table] ??= {}).addAll(topology.displayable);
    for (final q in questions) {
      for (var i = 0; i < q.logicChecks.length; i++) {
        final id = LogicTally.idFor(table, q.fieldName, i, q.logicChecks[i].condition);
        _logic.putIfAbsent(id, LogicTally.new);
        _logicTable[id] = table;
      }
    }
    final rules = _declaredRules[table] ??= {};
    for (final rule in topology.rules) {
      rules.add(rule.id);
      _ruleTable[rule.id] = table;
    }

    // A preskip jumps from its own question; a postskip from the one after.
    // Everything in between is a question this rule can close the route to
    // -- which is what lets a never-reached finding name the rules
    // responsible instead of just stating the fact. `SkipTopology` also
    // resolves the reserved target `end`, which a plain `indexWhere` on
    // fieldnames used to miss: a rule that skipped to the end of the form
    // was recorded here as jumping over nothing.
    for (final entry in topology.rulesJumpingOver.entries) {
      (_rulesJumpingOver[entry.key] ??= {})
          .addAll(entry.value.map((r) => r.id));
    }
  }

  void observe(Scenario scenario, {required int seed}) {
    _runs++;
    _records += scenario.recordCount;

    for (final run in [scenario.parent, ...scenario.children]) {
      _formsRun.add(run.tableName);
      _seen.addAll(run.route);
      _decisions[run.tableName]?.observe(run);
      for (final e in run.logicTallies.entries) {
        (_logic[e.key] ??= LogicTally()).merge(e.value);
      }
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
        _findings.add(
          Finding(
            code: 'unanswerable',
            table: run.tableName,
            field: field,
            seed: seed,
            detail:
                'had nothing to select: the csv or database filter matched no '
                'rows for the answers given, so the interviewer sees an empty '
                'list.',
          ),
        );
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
    for (final oneOff in scenario.oneOffs) {
      final tally = _oneOffs[oneOff.childTable] ??= OneOffTally(oneOff.entryCondition);
      tally.parents++;
      if (oneOff.qualified) tally.qualified++;
      if (oneOff.entered) tally.entered++;
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
    final decisions = {
      for (final entry in _decisions.entries) entry.key: entry.value.build(),
    };

    final report = RunReport(
      runs: _runs,
      records: _records,
      findings: List.unmodifiable([
        ..._findings,
        ..._coverageFindings(),
        ..._fallThroughFindings(decisions),
        ..._inertLogicFindings(),
      ]),
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
      steering: List.unmodifiable(_steering),
      decisions: Map.unmodifiable(decisions),
      logicChecks: Map.unmodifiable(_logic),
      oneOffs: Map.unmodifiable(_oneOffs),
      informationQuestions: {
        for (final t in _topologies.values) ...t.informationQuestions,
      },
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
                ? 'not tested. This app drives the base form and its child '
                      'forms, and this form is none of those -- so this is a '
                      'gap in the harness, not in the package.'
                : _oneOffs.containsKey(table)
                    ? 'no parent met its entry condition '
                          '(${_oneOffs[table]!.condition}) in $_runs interview(s), '
                          'so it was never opened and nothing in it was tested.'
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
                '${_whyUnreachable(field)}'
                '${_steeringNote(field, SteerPurpose.reach)}',
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
                'first and this one sits behind it.'
                '${_steeringNote(id, SteerPurpose.fire)}',
          ),
        );
      } else if (fired && !_notFired.contains(id)) {
        // A postskip on an information screen that always fires is the
        // screen doing its job: the screen is shown only on the branch its
        // own preskips leave open, and the postskip carries that branch on.
        // The rule is still counted in the coverage summary; it is not a
        // problem to report.
        final rule = _topologies[table]?.rule(id);
        if (rule != null &&
            !rule.isPreskip &&
            (_topologies[table]?.informationQuestions.contains(rule.owner) ?? false)) {
          continue;
        }
        findings.add(
          Finding(
            code: 'skip_rule_always_fired',
            table: table,
            field: name,
            detail:
                'fired every time it was evaluated, so the questions it '
                'jumps over were never asked on any route through this rule.'
                '${_steeringNote(id, SteerPurpose.notFire)}',
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
                'taken.${_steeringNote(id, SteerPurpose.fire)}',
          ),
        );
      }
    }

    return findings;
  }

  /// An information screen with postskips is a terminal screen -- "not
  /// eligible, thank them and stop" -- and its postskips are meant to carry
  /// every route past the questions that follow. One that was fallen through
  /// asked the rest of the form of someone it had just declared finished.
  List<Finding> _fallThroughFindings(Map<String, SkipDecisionTable> decisions) {
    final findings = <Finding>[];
    for (final table in decisions.values) {
      for (final screen in table.informationScreens) {
        final n = table.fallThrough[screen] ?? 0;
        if (n == 0) continue;
        final values = (table.fallThroughValues[screen] ?? const {}).entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final seen = values.map((e) => '${e.key} ×${e.value}').take(6).join(', ');
        findings.add(
          Finding(
            code: 'information_screen_fell_through',
            table: table.table,
            field: screen,
            detail:
                'an information screen with postskips is a terminal screen, '
                'but on $n interview-hop(s) none of its postskips fired and the '
                'interview carried on to the next question in sequence. '
                'Values of the tested fields when it happened: $seen.',
          ),
        );
      }
    }
    return findings;
  }

  /// A check that compares against a field skipped on every route to it.
  ///
  /// The engine passes a check whose operand is blank, so such a check never
  /// fires -- and when the blank field is one a skip rule jumps over, that is
  /// the form's own doing rather than a respondent's. The designer probably
  /// meant the check for a route the skips no longer allow.
  List<Finding> _inertLogicFindings() {
    if (_runs == 0) return const [];
    final findings = <Finding>[];
    for (final entry in _logic.entries) {
      final tally = entry.value;
      if (tally.evaluated == 0 || tally.nullOperand < tally.evaluated) continue;
      final table = _logicTable[entry.key] ?? '';
      final topology = _topologies[table];
      if (topology == null) continue;
      final skipped = tally.nullFields.keys
          .where((f) => (topology.rulesJumpingOver[f] ?? const []).isNotEmpty)
          .toList();
      if (skipped.isEmpty) continue;
      final rules = {
        for (final f in skipped)
          for (final r in topology.rulesJumpingOver[f]!) r.nameIn(table).split(' ').first,
      };
      final name = entry.key.startsWith('$table.')
          ? entry.key.substring(table.length + 1)
          : entry.key;
      findings.add(
        Finding(
          code: 'logic_check_inert',
          table: table,
          field: name,
          detail:
              'was evaluated ${tally.evaluated} time(s) and every time '
              '${skipped.join(', ')} was blank -- skipped by ${rules.join(', ')} '
              'on every route that reaches this check. A blank operand passes, '
              'so the check can never fire.',
        ),
      );
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
