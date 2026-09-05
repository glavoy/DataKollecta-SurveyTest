import 'dart:io';

import 'package:datakollecta/services/db_service.dart';
import 'package:datakollecta/services/repeat_count_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:surveytest/installer.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/scenario_runner.dart';
import 'package:surveytest/sim/virtual_respondent.dart';

File? findPackage() {
  final f = File('/Users/glavoy/temp/prism_css_test_2026_08_23.zip');
  return f.existsSync() ? f : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late InstalledPackage pkg;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'surveytest',
      packageName: 'com.datakollecta.surveytest',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('surveytest_scenario');
    await Sandbox.install(root);
    if (findPackage() != null) {
      pkg = await const PackageInstaller().install(findPackage()!);
    }
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// PRISM's parent only starts its repeat loops when the household enrolled
  /// and the counts were answered, so a seed that walks the not-enrolled path
  /// produces no children at all. Search for one that does.
  Future<Scenario?> enrolledScenario({
    Map<String, int>? childrenToComplete,
    bool acceptCountUpdate = true,
    int maxSeeds = 40,
  }) async {
    for (var seed = 0; seed < maxSeeds; seed++) {
      final scenario = await ScenarioRunner(
        surveyId: pkg.surveyId,
        respondent: VirtualRespondent(seed: seed),
        childrenToComplete: childrenToComplete,
        acceptCountUpdate: acceptCountUpdate,
      ).run('hh_info');
      if (scenario.repeats.isNotEmpty) return scenario;
    }
    return null;
  }

  test('a parent leads to its children, linked and numbered', () async {
    if (findPackage() == null) {
      markTestSkipped('No PRISM package available.');
      return;
    }

    final scenario = await enrolledScenario();
    expect(scenario, isNotNull,
        reason: '40 seeds produced no household that starts a repeat loop');

    expect(scenario!.livelocked, isFalse);
    expect(scenario.children, isNotEmpty);

    final db = await DbService.getDatabaseForQueries(pkg.surveyId);
    final parentKey = scenario.parent.storedRow['hhid'];
    expect(parentKey, isNot('-9'));

    for (final repeat in scenario.repeats) {
      final rows = await db.query(
        repeat.childTable,
        where: 'hhid = ?',
        whereArgs: [parentKey],
      );
      expect(rows.length, repeat.entered,
          reason: '${repeat.childTable}: rows on disk should match what saved');

      // Every child carries the parent's immutable uniqueid, not just its
      // business key -- the whole point of parent_uniqueid.
      for (final row in rows) {
        expect(row['parent_uniqueid'], scenario.parent.uniqueId,
            reason: '${repeat.childTable}: child not tied to its parent');
      }

      // The sibling ordinal is contiguous from 1, with no gaps, no duplicates
      // and never the degraded 0. Nothing in the database enforces this --
      // deliberately, since a failed insert would lose an interview -- so this
      // check is the only thing that would find a counter bug.
      final crf = await DbService.getCrfConfig(pkg.surveyId, repeat.childTable);
      final incrementField = crf?['incrementfield']?.toString();
      if (incrementField != null && incrementField.isNotEmpty && rows.isNotEmpty) {
        final ordinals = rows
            .map((r) => int.tryParse('${r[incrementField]}') ?? -1)
            .toList()
          ..sort();
        expect(ordinals, List.generate(rows.length, (i) => i + 1),
            reason: '${repeat.childTable}.$incrementField should be 1..N');
      }
    }
  });

  test('entering fewer children than declared reconciles the parent count',
      () async {
    if (findPackage() == null) {
      markTestSkipped('No PRISM package available.');
      return;
    }

    // PRISM ships every child at auto_start_repeat=2, repeat_enforce_count=3
    // -- update silently. Completing one fewer than declared should rewrite
    // the parent's count rather than leave it overstated.
    final scenario = await enrolledScenario(
      childrenToComplete: {'hh_members': 1, 'sleeping_structure': 1, 'nets': 1},
    );
    expect(scenario, isNotNull);

    for (final repeat in scenario!.repeats) {
      if (repeat.enforceMode != 3) continue;
      if (repeat.entered == repeat.declared) continue;
      // Mode 3 writes unconditionally, but never outside the count question's
      // own LowerRange -- so a count it refused to write is a legitimate
      // aboveMaximum/belowMinimum, not a failure.
      if (repeat.outcome == RepeatCountOutcome.belowMinimum ||
          repeat.outcome == RepeatCountOutcome.aboveMaximum) {
        continue;
      }
      expect(repeat.countAfter, repeat.entered,
          reason: '${repeat.childTable}: mode 3 should have corrected '
              '${repeat.countField} to what was actually entered');
    }
  });

  test('a mismatch declined by the interviewer leaves the count alone',
      () async {
    if (findPackage() == null) {
      markTestSkipped('No PRISM package available.');
      return;
    }

    final scenario = await enrolledScenario(
      childrenToComplete: {'hh_members': 1, 'sleeping_structure': 1, 'nets': 1},
      acceptCountUpdate: false,
    );
    expect(scenario, isNotNull);

    for (final repeat in scenario!.repeats) {
      if (repeat.acceptedUpdate == false) {
        expect(repeat.countAfter, repeat.declared,
            reason: '${repeat.childTable}: declining the offer must not '
                'rewrite the count');
      }
    }
  });
}
