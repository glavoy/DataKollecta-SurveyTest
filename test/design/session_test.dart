import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/report.dart';
import 'package:surveytest/sim/session.dart';

import '../support/fixture_package.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    initTestEnvironment();
    root = await Directory.systemTemp.createTemp('surveytest_session');
    await Sandbox.install(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a batch of interviews reports coverage and any findings', () async {
    final pkg = await installFixture('household_repeat', root);
    final session = SimulationSession(pkg);

    var lastDone = 0;
    final report = await session.run(
      const RunSettings(runs: 10, seed: 20260905),
      onProgress: (done, total) => lastDone = done,
    );

    // Steered interviews run alongside the 10 asked for, so the totals are
    // "at least" -- and every one of them must have been counted.
    expect(lastDone, report.runs, reason: 'progress should reach the end');
    expect(report.runs, greaterThanOrEqualTo(10));
    expect(report.records, greaterThanOrEqualTo(report.runs));
    expect(report.questionsSeen, containsAll(['district', 'hhnum', 'enrolled', 'name']));
    expect(report.repeatCells, {'2/3'});

    final counts = await session.recordCounts();
    expect(counts['hh'], report.runs);
    expect(counts['member'], greaterThan(0));

    // The follow-up is entered by hand in the field, once per parent that
    // meets its entry condition. The harness does the same, so it is not
    // reported as never entered, and the coverage says how many qualified.
    expect(report.findings.where((f) => f.code == 'form_never_entered'), isEmpty);
    expect(counts['followup'], greaterThan(0));
    final followup = report.oneOffs['followup']!;
    expect(followup.condition, 'enrolled=1');
    expect(followup.parents, report.runs);
    expect(followup.entered, followup.qualified);
    expect(followup.qualified, counts['followup']);

    // Every finding from a single interview names its seed, or it cannot be
    // reproduced. Batch-level findings deliberately do not: "no run reached
    // this question" is a property of the whole batch.
    for (final finding in report.findings) {
      if (isBatchLevel(finding.code)) {
        expect(finding.seed, isNull, reason: '${finding.code} names a seed');
      } else {
        expect(finding.seed, isNotNull, reason: '${finding.code} has no seed');
      }
    }

    // A well-formed package produces no engine-integrity finding.
    expect(report.engineFindings, isEmpty,
        reason: report.engineFindings.map((f) => '${f.where} ${f.code}: ${f.detail}').join('\n'));
  });

  test('the same seed produces the same findings', () async {
    Future<List<String>> findingsFor() async {
      final pkg = await installFixture('household_repeat', root);
      final report = await SimulationSession(pkg).run(const RunSettings(runs: 6, seed: 99));
      return report.findings.map((f) => '${f.where}:${f.code}').toList();
    }

    expect(await findingsFor(), await findingsFor(),
        reason: 'a report that cannot be reproduced cannot be acted on');
  });

  test('engine checks can be switched off for a designer\'s quick run', () async {
    final pkg = await installFixture('household_repeat', root);
    final report = await SimulationSession(pkg).run(
      const RunSettings(runs: 4, seed: 5, engineChecks: false, steer: false),
    );
    expect(report.runs, 4);
    expect(report.engineFindings, isEmpty);
  });
}
