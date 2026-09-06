import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:surveytest/lint/package_lint.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/session.dart';

import '../support/fixture_package.dart';

/// Each fixture here is a dictionary with exactly one thing wrong with it,
/// and the lint must say exactly that -- no more, or a real report drowns in
/// noise; no less, or the defect ships.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    initTestEnvironment();
    root = await Directory.systemTemp.createTemp('surveytest_lint');
    await Sandbox.install(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Runs the lint on a fixture and asserts it reports [code] on [fields]
  /// and nothing else.
  Future<String> expectOnly(
    String fixture,
    String code,
    Set<String> fields,
  ) async {
    final pkg = await installFixture(fixture, root);
    final findings = await const PackageLint().run(pkg);
    expect(
      findings.map((f) => f.code).toSet(),
      {code},
      reason: '$fixture: ${findings.map((f) => '${f.where} ${f.code}').join('; ')}',
    );
    expect(findings.map((f) => f.field ?? f.table).toSet(), fields);
    return findings.map((f) => f.detail).join('\n');
  }

  test('a clean package produces no lint findings', () async {
    for (final fixture in ['malaria_screening', 'trap_logic', 'deep_gate']) {
      final pkg = await installFixture(fixture, root);
      final findings = await const PackageLint().run(pkg);
      expect(findings, isEmpty,
          reason: '$fixture: ${findings.map((f) => '${f.where} ${f.code}: ${f.detail}').join('; ')}');
    }
  });

  test('skip_domain_gap: Yes and No routed, Don\'t know forgotten', () async {
    final detail = await expectOnly('dk_fallthrough', 'skip_domain_gap', {'fever.postskip'});
    expect(detail, contains("-7 (Don't know)"));
    expect(detail, contains('falls through to between'));
    expect(detail, contains('covers every answer'));
  });

  test('the info_fallthrough fixture is the single-rule shape of the same gap',
      () async {
    // `not_eligible` has one preskip (eligible = 1) and one postskip
    // (eligible = 0). Each cell singles out one real answer and leaves -7
    // to fall through; both are worth a look.
    final detail = await expectOnly(
      'info_fallthrough',
      'skip_domain_gap',
      {'not_eligible.preskip', 'not_eligible.postskip'},
    );
    expect(detail, contains('a <> rule covers the codes too'));
  });

  test('special_code_routed_as_value: age < 18 is true for -7', () async {
    final detail = await expectOnly(
      'special_as_number',
      'special_code_routed_as_value',
      {'adult_q.preskip[0] age < 18 -> end'},
    );
    expect(detail, contains('-7'));
  });

  test('logic_check_malformed', () async {
    // `age 18` has no operator at all, which the engine reports as a parse
    // error. (An unknown operator like `>>` is SurveyGen's check now.)
    final detail = await expectOnly('logic_malformed', 'logic_check_malformed', {'age.logic[0]'});
    expect(detail, contains('age 18'));
    expect(detail, contains('Next button'));
  });

  test('csv_cascade_empty', () async {
    final detail = await expectOnly('csv_cascade_empty', 'csv_cascade_empty', {'village'});
    expect(detail, contains('region=3'));
    expect(detail, contains('1 of 3'));
  });

  test('an empty filtered list at run time is a dead end, not a dead question',
      () async {
    // Region 3 leaves `village` with nothing to select. An interviewer goes
    // back and changes the region; so does the runner -- and the lint above
    // is where the defect itself is reported.
    final pkg = await installFixture('csv_cascade_empty', root);
    final report = await SimulationSession(pkg).run(const RunSettings(runs: 30, seed: 3));
    expect(report.findings.where((f) => f.code == 'cannot_advance'), isEmpty);
    expect(report.findings.where((f) => f.code == 'unanswerable'), isEmpty);
    expect(report.deadEnds.keys, contains('village'));
    expect(report.questionsSeen, contains('after'));
  });

  test('skip_dropped_by_parser', () async {
    final detail = await expectOnly('skip_dropped', 'skip_dropped_by_parser', {'form'});
    expect(detail, contains('declares 1'));
  });
}
