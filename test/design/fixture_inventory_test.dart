import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:surveytest/installer.dart';
import 'package:surveytest/lint/package_lint.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/report.dart';

import '../support/fixture_package.dart';

/// Holds every fixture to the row it has in `test/fixtures/README.md`.
///
/// Two things this guards. A new check that quietly fires on an old fixture
/// shows up here as an unexpected code, before it shows up as noise on a
/// real report. And a fixture that stops tripping its own code -- because
/// the engine changed underneath -- shows up as a missing one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Fixture -> the lint codes it must produce, exactly.
  const lint = <String, Set<String>>{
    'malaria_screening': {},
    'trap_logic': {},
    'deep_gate': {},
    'household_repeat': {},
    'query_calc_lookup': {},
    'logic_inert': {},
    'info_fallthrough': {'skip_domain_gap'},
    'dk_fallthrough': {'skip_domain_gap'},
    'special_as_number': {'special_code_routed_as_value'},
    'logic_malformed': {'logic_check_malformed'},
    'csv_cascade_empty': {'csv_cascade_empty'},
    'skip_dropped': {'skip_dropped_by_parser'},
  };

  /// Fixture -> a fragment of the message its install must be refused with.
  ///
  /// The third kind of fixture, and the reason `every fixture on disk has a
  /// row` unions three maps rather than reading `lint` alone: these never
  /// install, so they produce no code and no run. A dictionary the app cannot
  /// use is refused outright rather than degraded, and what has to stay true
  /// is that the refusal reaches a designer naming the package and the
  /// question -- which is asserted in full in `test/engine/installer_test.dart`.
  const refused = <String, String>{
    'query_calc_sql': 'single SELECT',
  };

  /// Fixture -> the design code a run must produce, when the lint alone
  /// cannot.
  const runtime = <String, String>{
    'malaria_screening': 'question_never_reached',
    'trap_logic': 'cannot_advance',
    'info_fallthrough': 'information_screen_fell_through',
    'logic_inert': 'logic_check_inert',
  };

  late Directory root;

  setUp(() async {
    initTestEnvironment();
    root = await Directory.systemTemp.createTemp('surveytest_inventory');
    await Sandbox.install(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('every fixture on disk has a row', () {
    expect(fixtureNames().toSet(), {...lint.keys, ...refused.keys});
  });

  for (final entry in refused.entries) {
    test('${entry.key}: the package is refused, not degraded', () async {
      expect(
        () => installFixture(entry.key, root),
        throwsA(isA<InstallException>()
            .having((e) => e.message, 'message', contains(entry.value))),
      );
    });
  }

  for (final entry in lint.entries) {
    test('${entry.key}: lint reports exactly ${entry.value}', () async {
      final pkg = await installFixture(entry.key, root);
      final findings = await const PackageLint().run(pkg);
      expect(
        findings.map((f) => f.code).toSet(),
        entry.value,
        reason: findings.map((f) => '${f.where} ${f.code}: ${f.detail}').join('\n'),
      );
    });
  }

  for (final entry in runtime.entries) {
    test('${entry.key}: a run reports ${entry.value}, and the engine stays clean',
        () async {
      final report = await runFixture(entry.key, root, runs: 12);
      expect(report.findings.map((f) => f.code), contains(entry.value));
      expect(
        report.engineFindings,
        isEmpty,
        reason: report.engineFindings.map((f) => '${f.where} ${f.code}: ${f.detail}').join('\n'),
      );
    });
  }

  test('the engine stays clean on every fixture a run can save', () async {
    for (final name in [
      'deep_gate',
      'household_repeat',
      'dk_fallthrough',
      'csv_cascade_empty',
      'query_calc_lookup',
    ]) {
      final report = await runFixture(name, root, runs: 6);
      expect(
        report.engineFindings.where((f) => f.code != 'save_failed').map((f) => '$name ${f.where} ${f.code}'),
        isEmpty,
      );
      expect(report.designFindings.map((f) => f.tier).toSet(), anyOf(isEmpty, {FindingTier.design}));
    }
  });
}
