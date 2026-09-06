import 'dart:io';

import 'package:datakollecta/models/question.dart';
import 'package:datakollecta/services/db_service.dart';
import 'package:datakollecta/services/field_comparator.dart';
import 'package:datakollecta/services/survey_config_service.dart';
import 'package:datakollecta/services/survey_loader.dart';

import '../installer.dart';
import '../lint/package_lint.dart';
import 'invariants.dart';
import 'report.dart';
import 'scenario_runner.dart';
import 'steering.dart';
import 'virtual_respondent.dart';

/// How a run is configured.
class RunSettings {
  const RunSettings({
    this.runs = 100,
    this.seed,
    this.strategies = const [
      RespondentStrategy.random,
      RespondentStrategy.boundaryValues,
      RespondentStrategy.skipMaximising,
      RespondentStrategy.skipAvoiding,
      RespondentStrategy.dontKnowHeavy,
    ],
    this.backtrackRate = 0.15,
    this.steer = true,
    this.engineChecks = true,
  });

  final int runs;

  /// Null means "pick one and report it", so a run is always replayable even
  /// when the designer did not choose a seed.
  final int? seed;

  final List<RespondentStrategy> strategies;

  /// How often the interviewer goes back a question. Going back and forward
  /// again is the only way to reach some of what the engine does.
  final double backtrackRate;

  /// Whether to run the steered interviews: two per skip rule (one to make it
  /// fire, one to keep it from firing) and one per question the random
  /// interviews never reached. With this off, "never fired" and "never
  /// reached" are statements about luck; with it on they are evidence.
  final bool steer;

  /// Whether to run the engine-integrity checks on every saved record --
  /// answers stored unchanged, keys unique, timestamps ordered. A designer
  /// checking a dictionary can turn these off; an app developer should not.
  final bool engineChecks;
}

/// Runs a batch of interviews against an installed package and reports.
class SimulationSession {
  const SimulationSession(this.package);

  final InstalledPackage package;

  /// The form to start from -- the base form, or the only form there is.
  String get startTable =>
      (package.baseCrf?['tablename'] ?? package.crfs.first['tablename'])
          .toString();

  Future<RunReport> run(
    RunSettings settings, {
    void Function(int done, int total)? onProgress,
  }) async {
    final base = settings.seed ?? ReportBuilder.randomSeed();
    final builder = ReportBuilder();
    final invariants = Invariants(package.surveyId);

    // Teach the report what the package contains before running anything.
    // Coverage is the difference between what a package declares and what the
    // interviews did; without this half the report can say how many questions
    // were reached but not which were missed, which is precisely the shape of
    // defect -- a skip pattern that closes every route to a block of
    // questions -- that a simulator is best placed to find.
    await _declareForms(builder);

    // Phase 0: what the package says about itself, before any interview.
    for (final finding in await const PackageLint().run(package)) {
      builder.add(finding);
    }

    var done = 0;
    var total = settings.runs;
    var nextSeed = 0;

    Future<void> interview(
      VirtualRespondent respondent, {
      required int seed,
      SteeringPlan? plan,
    }) async {
      // Every rule this one interview saw, and how, so a steered run can be
      // judged on what the engine reported rather than on what was asked for.
      final observed = <String, Set<bool>>{};
      final scenario = await ScenarioRunner(
        surveyId: package.surveyId,
        respondent: respondent,
        onSkipEvaluated: (id, fired) {
          builder.observeSkip(id, fired);
          (observed[id] ??= {}).add(fired);
        },
      ).run(startTable);

      builder.observe(scenario, seed: seed);
      if (settings.engineChecks) {
        for (final finding in await invariants.check(scenario, seed: seed)) {
          builder.add(finding);
        }
      }
      if (plan != null) {
        builder.observeSteering(_judge(plan, scenario, observed, respondent, seed));
      }
      done++;
      onProgress?.call(done, total);
    }

    // Phase 1: one interview per plan, so every rule is tried both ways and
    // a rule that then still never fired was not merely unlucky.
    if (settings.steer) {
      final plans = _dedupe([
        for (final table in _drivableTables())
          if (builder.topologyOf(table) != null)
            ...SteeringPlanner.forRules(builder.topologyOf(table)!),
      ]);
      total += plans.length;
      for (final plan in plans) {
        if (!plan.feasible) {
          // Nothing an interviewer could answer satisfies this plan; running
          // it would prove nothing. The contradiction itself is the result.
          builder.observeSteering(
            SteeringOutcome(
              plan: plan,
              seed: null,
              achieved: false,
              reason: _contradictionText(plan),
              valuesChosen: const {},
            ),
          );
          // Not an interview, so not progress: shrink the total instead.
          total--;
          onProgress?.call(done, total);
          continue;
        }
        final seed = ReportBuilder.seedFor(base, nextSeed++);
        await interview(
          VirtualRespondent(
            seed: seed,
            strategy: RespondentStrategy.random,
            backtrackRate: 0,
            targets: _targetsFor(plan, builder),
          ),
          seed: seed,
          plan: plan,
        );
      }
    }

    // Phase 2: the random strategies, which reach what nobody planned for.
    for (var i = 0; i < settings.runs; i++) {
      final seed = ReportBuilder.seedFor(base, nextSeed++);
      final strategy = settings.strategies[i % settings.strategies.length];
      await interview(
        VirtualRespondent(
          seed: seed,
          strategy: strategy,
          backtrackRate: settings.backtrackRate,
        ),
        seed: seed,
      );
    }

    // Phase 3: one deliberate attempt at every question still not seen.
    if (settings.steer) {
      final reachPlans = <SteeringPlan>[];
      for (final table in _drivableTables()) {
        final topology = builder.topologyOf(table);
        if (topology == null) continue;
        for (final q in topology.displayable) {
          if (builder.wasSeen(q)) continue;
          reachPlans.add(SteeringPlanner.toReach(topology, q));
        }
      }
      total += reachPlans.length;
      for (final plan in reachPlans) {
        if (!plan.feasible) {
          builder.observeSteering(
            SteeringOutcome(
              plan: plan,
              seed: null,
              achieved: false,
              reason: _contradictionText(plan),
              valuesChosen: const {},
            ),
          );
          // Not an interview, so not progress: shrink the total instead.
          total--;
          onProgress?.call(done, total);
          continue;
        }
        final seed = ReportBuilder.seedFor(base, nextSeed++);
        await interview(
          VirtualRespondent(
            seed: seed,
            strategy: RespondentStrategy.random,
            backtrackRate: 0,
            targets: _targetsFor(plan, builder),
          ),
          seed: seed,
          plan: plan,
        );
      }
    }

    return builder.build();
  }

  /// The constraints a steered interview carries, by table.
  ///
  /// A plan on a child form is only testable if the parent actually opens
  /// that child, so the parent is steered too: its `entry_condition` made
  /// true and its `repeat_count_field` made positive, with every rule that
  /// could jump over either of those fields held off. Without this the
  /// child's plans were judged on interviews that never entered the child
  /// at all, which said nothing about the child.
  Map<String, Map<String, List<SteerConstraint>>> _targetsFor(
    SteeringPlan plan,
    ReportBuilder builder,
  ) {
    final targets = <String, Map<String, List<SteerConstraint>>>{
      plan.table: plan.constraintsByField,
    };
    final crf = package.crfs.firstWhere(
      (c) => c['tablename']?.toString() == plan.table,
      orElse: () => const {},
    );
    final parentTable = crf['parenttable']?.toString() ?? '';
    final parentTopology = builder.topologyOf(parentTable);
    if (parentTable.isEmpty || parentTopology == null) return targets;

    final parent = <String, List<SteerConstraint>>{};
    void require(String field, String condition, String value) {
      if (!parentTopology.displayable.contains(field)) return;
      (parent[field] ??= []).add(
        SteerConstraint(
          ruleId: '$parentTable.crfs',
          field: field,
          condition: condition,
          response: value,
          responseType: 'fixed',
          wantFire: true,
        ),
      );
      final open = SteeringPlanner.toReach(parentTopology, field);
      for (final entry in open.constraintsByField.entries) {
        final list = parent[entry.key] ??= [];
        for (final c in entry.value) {
          if (!list.any((e) => e.key == c.key)) list.add(c);
        }
      }
    }

    final entry = crf['entry_condition']?.toString() ?? '';
    final eq = entry.indexOf('=');
    if (eq > 0) {
      require(entry.substring(0, eq).trim(), '=', entry.substring(eq + 1).trim());
    }
    final countField = crf['repeat_count_field']?.toString() ?? '';
    if (countField.isNotEmpty) require(countField, '>', '0');

    if (parent.isNotEmpty) targets[parentTable] = parent;
    return targets;
  }

  /// The base form and every child of it: the ones the repeat loop opens and
  /// the ones an interviewer opens by hand for a parent that meets the
  /// `entry_condition`. `ScenarioRunner` drives both.
  Set<String> _drivableTables() => {
        startTable,
        for (final child in package.repeatingChildren)
          if ((child['tablename']?.toString() ?? '').isNotEmpty)
            child['tablename'].toString(),
      };

  /// Plans with identical constraints prove the same thing; run one.
  List<SteeringPlan> _dedupe(List<SteeringPlan> plans) {
    final seen = <String>{};
    return [
      for (final p in plans)
        if (seen.add('${p.purpose}|${p.subject}|${p.signature}')) p,
    ];
  }

  SteeringOutcome _judge(
    SteeringPlan plan,
    Scenario scenario,
    Map<String, Set<bool>> observed,
    VirtualRespondent respondent,
    int seed,
  ) {
    final runs = [scenario.parent, ...scenario.children];
    final enteredForm = runs.any((r) => r.tableName == plan.table);
    final values = Map<String, Object?>.of(respondent.steeredValues);

    bool achieved;
    String reason;
    if (!enteredForm) {
      achieved = false;
      reason = 'the form ${plan.table} was never entered on this interview';
    } else if (plan.purpose == SteerPurpose.reach) {
      achieved = runs.any((r) => r.route.contains(plan.subject));
      reason = achieved ? '' : 'the question was still not displayed';
    } else {
      final want = plan.purpose == SteerPurpose.fire;
      final seen = observed[plan.subject];
      if (seen == null) {
        achieved = false;
        reason = 'the rule was never evaluated';
      } else {
        achieved = seen.contains(want);
        reason = achieved
            ? ''
            : 'the rule was evaluated but ${want ? 'did not fire' : 'fired'}';
      }
    }
    if (!achieved && respondent.steerFailed.isNotEmpty) {
      reason += '; no answer to ${respondent.steerFailed.join(', ')} '
          'satisfied every constraint';
    }
    if (!achieved) {
      // A steered value the gate refused was replaced by the strategy's, so
      // the plan was not actually tested on that field. Say which.
      final refused = <String>[];
      for (final run in runs) {
        for (final entry in values.entries) {
          if (!run.route.contains(entry.key)) continue;
          final kept = run.answers[entry.key];
          if (!_sameValue(kept, entry.value)) {
            refused.add(
              '${entry.key} (${FieldComparator.resolveText(entry.value) ?? '(blank)'} '
              'refused by a gate, ${FieldComparator.resolveText(kept) ?? '(blank)'} kept)',
            );
          }
        }
      }
      if (refused.isNotEmpty) {
        reason += '; steered values were refused: ${refused.toSet().join(', ')}';
      }
    }
    return SteeringOutcome(
      plan: plan,
      seed: seed,
      achieved: achieved,
      reason: reason,
      valuesChosen: values,
    );
  }

  static bool _sameValue(Object? a, Object? b) =>
      FieldComparator.resolveText(a) == FieldComparator.resolveText(b);

  static String _contradictionText(SteeringPlan plan) {
    final pairs = plan.contradictions
        .map((c) => '${c.$1.ruleId} needs ${c.$1} while ${c.$2.ruleId} needs ${c.$2}')
        .join('; ');
    return 'no answer can satisfy this: $pairs';
  }

  /// Loads every form's questions once and hands them to the report.
  ///
  /// A form whose XML is missing is left undeclared rather than throwing --
  /// the installer already refuses a package it cannot read, and a run that
  /// reports slightly less is better than one that reports nothing.
  Future<void> _declareForms(ReportBuilder builder) async {
    final drivable = _drivableTables();

    for (final crf in package.crfs) {
      final table = crf['tablename']?.toString();
      if (table == null || table.isEmpty) continue;

      final path = await SurveyConfigService().getQuestionnaireAssetPath(
        '$table.xml',
      );
      if (path == null) continue;

      final List<Question> questions = await SurveyLoader.loadFromFile(
        File(path),
      );
      builder.declareForm(
        table,
        questions,
        reachable: drivable.contains(table),
      );
    }
  }

  /// How many records the package holds now, per table. Shown after a run so
  /// the designer can go and look at them.
  Future<Map<String, int>> recordCounts() async {
    final counts = <String, int>{};
    for (final crf in package.crfs) {
      final table = crf['tablename']?.toString();
      if (table == null || table.isEmpty) continue;
      counts[table] = await DbService.getRecordCount(
        surveyId: package.surveyId,
        tableName: table,
      );
    }
    return counts;
  }
}

