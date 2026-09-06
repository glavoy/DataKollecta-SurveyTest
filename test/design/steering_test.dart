import 'dart:io';

import 'package:datakollecta/services/survey_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/skip_topology.dart';
import 'package:surveytest/sim/steering.dart';
import 'package:surveytest/sim/virtual_respondent.dart';

import '../support/fixture_package.dart';

/// Steering turns "never reached" and "never fired" from statements about
/// luck into evidence: an interview that was *trying* to get there and could
/// not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    initTestEnvironment();
    root = await Directory.systemTemp.createTemp('surveytest_steering');
    await Sandbox.install(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('the planner', () {
    late SkipTopology topology;

    setUp(() async {
      final questions = await SurveyLoader.loadFromFile(
        File('test/fixtures/malaria_screening/malaria_screening.xml'),
      );
      topology = SkipTopology.of('malaria_screening', questions);
    });

    test('resolves the reserved target end to past the last question', () async {
      final questions = await SurveyLoader.loadFromFile(
        File('test/fixtures/info_fallthrough/screening.xml'),
      );
      final t = SkipTopology.of('screening', questions);
      final toEnd = t.rules.singleWhere((r) => r.target == 'end');
      expect(toEnd.targetIndex, questions.length);
      // The rule jumps over everything after its question -- which the old
      // indexWhere-based bookkeeping recorded as nothing at all.
      expect(t.rulesJumpingOver['q1'], contains(toEnd));
      expect(t.rulesJumpingOver['q2'], contains(toEnd));
    });

    test('to fire a shadowed preskip, the rules in front of it must not', () {
      final plans = SteeringPlanner.forRules(topology);
      final fire = plans.singleWhere(
        (p) =>
            p.purpose == SteerPurpose.fire &&
            p.subject.startsWith('malaria_screening.symptoms.preskip[1]'),
      );
      final onSex = fire.constraintsByField['sex']!.map((c) => c.toString());
      // The earlier sibling `sex = 2` must not fire, and the postskip on
      // `sex` that jumps over `symptoms` must not fire either.
      expect(onSex, contains('sex not (= 2)'));
      expect(onSex, contains('sex not (= 1)'));
      expect(fire.constraintsByField['fever48h']!.single.toString(),
          'fever48h (<> 1)');
    });

    test('to reach a question, every rule that jumps over it must not fire', () {
      final plan = SteeringPlanner.toReach(topology, 'rdt_result');
      expect(plan.constraintsByField.keys, containsAll(['sex', 'rdt_done']));
      expect(plan.constraintsByField['rdt_done']!.single.wantFire, isFalse);
    });

    test('a rule asked to fire and not fire in one plan is a contradiction', () {
      final plan = SteeringPlan(
        table: 't',
        purpose: SteerPurpose.reach,
        subject: 'q',
        constraintsByField: const {},
        contradictions: const [],
      );
      expect(plan.feasible, isTrue);

      final a = SteerConstraint(
        ruleId: 'r', field: 'f', condition: '=', response: '1',
        responseType: 'fixed', wantFire: true,
      );
      final b = SteerConstraint(
        ruleId: 's', field: 'f', condition: '=', response: '1',
        responseType: 'fixed', wantFire: false,
      );
      expect(a.contradicts(b), isTrue);
      expect(a.satisfiedBy('1', const {}), isTrue);
      expect(b.satisfiedBy('1', const {}), isFalse);
      // Fail-open: a blank never fires, so it satisfies only "must not".
      expect(a.satisfiedBy(null, const {}), isFalse);
      expect(b.satisfiedBy(null, const {}), isTrue);
    });
  });

  group('deep_gate', () {
    test('random interviews alone call a reachable question unreachable',
        () async {
      // Uniform draws only: `skipAvoiding` would steer straight through the
      // gate, which is the point of steering and not what is under test here.
      final report = await runFixture(
        'deep_gate',
        root,
        runs: 20,
        steer: false,
        strategies: [RespondentStrategy.random],
      );
      expect(report.neverReached, contains('rare_q'));
      expect(
        report.findings.where((f) => f.code == 'question_never_reached'),
        isNotEmpty,
      );
    });

    test('a steered interview reaches it, and the finding goes away', () async {
      final report = await runFixture('deep_gate', root, runs: 20, steer: true);
      expect(report.questionsSeen, contains('rare_q'));
      expect(
        report.findings.where((f) => f.code == 'question_never_reached'),
        isEmpty,
      );
      // Every rule on the gate was exercised both ways.
      expect(report.skipsNeverFired, isEmpty);
      expect(report.skipsAlwaysFired, isEmpty);
      expect(report.steering.where((o) => !o.achieved), isEmpty);
    });
  });

  group('malaria_screening', () {
    test('a rule steering could not fire says so in its finding', () async {
      final report = await runFixture('malaria_screening', root, runs: 20);
      // `symptoms.preskip[1]` sits behind `sex = 2`, and `sex = 1` jumps over
      // `symptoms` from the other side -- there is no value of `sex` that
      // gets the engine to evaluate it. Steering tried and failed, and the
      // report must say that rather than leave it looking like bad luck.
      final shadowed = report.findings.firstWhere(
        (f) => f.code == 'skip_rule_never_evaluated' &&
            f.field!.startsWith('symptoms.preskip[1]'),
      );
      expect(shadowed.detail, contains('steered'));
    });
  });
}
