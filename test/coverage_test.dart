import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:surveytest/installer.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/report.dart';
import 'package:surveytest/sim/session.dart';
import 'package:surveytest/sim/virtual_respondent.dart';

import 'support/fixture_package.dart';

/// The defect this whole coverage mechanism exists for.
///
/// `test/fixtures/malaria_screening` is a real generated package with two
/// skips that between them cover every value of `sex`:
///
/// * `sex` carries `postskip: sex = 1 -> treatment`
/// * `symptoms` carries `preskip: sex = 2 -> comments`
///
/// So `sex = 1` jumps straight to `treatment`, and `sex = 2` reaches
/// `symptoms` and is immediately sent on to `comments`. Four questions can
/// never be displayed to anybody. Every per-row check in the generator passes,
/// the XML is valid, and before this the testing app ran hundreds of clean
/// interviews and said nothing -- it counted the questions it reached and
/// never the ones it did not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late InstalledPackage pkg;

  setUp(() async {
    initTestEnvironment();
    root = await Directory.systemTemp.createTemp('surveytest_coverage');
    await Sandbox.install(root);
    pkg = await const PackageInstaller().install(
      buildFixtureZip('malaria_screening', root),
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<RunReport> runBatch({int runs = 40}) =>
      SimulationSession(pkg).run(RunSettings(runs: runs, seed: 20260905));

  test('names every question no route can reach', () async {
    final report = await runBatch();

    expect(report.neverReached, {
      'symptoms',
      'symptom_days',
      'rdt_done',
      'rdt_result',
    });
  });

  test('reports them as problems, not as a quiet coverage number', () async {
    final report = await runBatch();

    final unreachable = report.findings
        .where((f) => f.code == 'question_never_reached')
        .map((f) => f.field)
        .toSet();

    expect(unreachable, {
      'symptoms',
      'symptom_days',
      'rdt_done',
      'rdt_result',
    });
    expect(report.clean, isFalse);
  });

  test('names the rules that closed the route', () async {
    final report = await runBatch();
    final finding = report.findings.firstWhere(
      (f) => f.field == 'symptom_days',
    );

    // The value of this over a bare "never reached" is that a designer is
    // told which pair of rules to look at.
    expect(finding.detail, contains('always fired'));
    expect(finding.detail, contains('malaria_screening.symptoms.preskip[0]'));
  });

  test('says nothing about the questions the sex = 2 route does reach',
      () async {
    final report = await runBatch();

    for (final reached in ['visit_date', 'facility', 'sex', 'comments']) {
      expect(report.questionsSeen, contains(reached));
      expect(report.neverReached, isNot(contains(reached)));
    }
  });

  test('an automatic field is not reported as unreached', () async {
    // `starttime` and friends are computed as navigation crosses them and are
    // never displayed, so counting them would put six permanent findings on
    // every healthy package.
    final report = await runBatch();

    for (final auto in ['starttime', 'uniqueid', 'stoptime', 'swver']) {
      expect(report.questionsDeclared, isNot(contains(auto)));
      expect(report.neverReached, isNot(contains(auto)));
    }
    expect(report.questionsDeclared, isNot(contains('end_of_questions')));
  });

  test('a rule behind one that always matches is never evaluated', () async {
    final report = await runBatch();

    // `symptoms` has two preskips. The first (`sex = 2`) matches on every
    // route that reaches the question, so the engine returns before trying
    // the second -- which is exactly how a shadowed rule shows up.
    final shadowed = report.skipsNeverEvaluated.where(
      (id) => id.startsWith('malaria_screening.symptoms.preskip[1]'),
    );
    expect(shadowed, hasLength(1));
  });

  test('every declared question and rule is accounted for', () async {
    final report = await runBatch();

    // Coverage is a difference, so the declared side must actually be
    // populated -- an empty universe would make every check above vacuous.
    expect(report.questionsDeclared, contains('rdt_result'));
    expect(report.skipsDeclared, hasLength(7));
    expect(
      report.skipsNeverEvaluated
          .union(report.skipsFired)
          .union(report.skipsNotFired),
      report.skipsDeclared,
    );
  });


  group('the Next button, as the app draws it', () {
    test('an impassable logic check is reported as a dead end', () async {
      // The real app computes
      // `canProceed = (isAnswered && isValid) && _logicError == null` and
      // passes null to onPressed when it is false, so an interviewer facing a
      // check no answer satisfies can neither move on nor finish. Before this
      // the runner recorded the message and walked on, producing routes -- and
      // saved rows -- the field app could never produce.
      final trap = await const PackageInstaller().install(
        buildFixtureZip('trap_logic', root),
      );
      final report = await SimulationSession(
        trap,
      ).run(const RunSettings(runs: 3, seed: 1));

      final dead = report.findings.where((f) => f.code == 'cannot_advance');
      expect(dead.map((f) => f.field).toSet(), {'age'});
      expect(dead.first.detail, contains('neither move on nor'));
    });

    test('a boundary-drawing respondent is not mistaken for a dead end',
        () async {
      // The false-positive guard. `boundaryValues` draws range ends and
      // `dontKnowHeavy` draws sentinels; if a few unlucky draws counted as
      // "impassable" the finding would be worthless. The last attempts ask
      // the respondent for a deliberately conservative answer instead, so
      // only a genuinely closed question is reported.
      final report = await SimulationSession(pkg).run(
        const RunSettings(
          runs: 20,
          seed: 7,
          strategies: [
            RespondentStrategy.boundaryValues,
            RespondentStrategy.dontKnowHeavy,
          ],
        ),
      );

      expect(
        report.findings
            .where((f) => f.code == 'cannot_advance')
            .map((f) => '${f.where}: ${f.detail}')
            .toSet(),
        isEmpty,
      );
    });
  });
}
