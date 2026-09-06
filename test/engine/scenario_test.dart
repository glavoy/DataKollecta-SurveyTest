import 'dart:io';

import 'package:datakollecta/services/db_service.dart';
import 'package:datakollecta/services/repeat_count_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surveytest/installer.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/scenario_runner.dart';
import 'package:surveytest/sim/virtual_respondent.dart';

import '../support/fixture_package.dart';

/// Harness self-tests: a parent and its repeating children go through the
/// field app's own `RepeatPlanService`, `RepeatLoopRunner` and
/// `RepeatCountService`. The reconciliation semantics themselves are covered
/// in the app repo; what is checked here is that this harness drives them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late InstalledPackage pkg;

  setUp(() async {
    initTestEnvironment();
    root = await Directory.systemTemp.createTemp('surveytest_scenario');
    await Sandbox.install(root);
    pkg = await installFixture('household_repeat', root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// The parent only starts its repeat loop when the household enrolled, so
  /// a seed that walks the not-enrolled path produces no children. Search
  /// for one that does.
  Future<Scenario?> enrolledScenario({
    Map<String, int>? childrenToComplete,
    bool acceptCountUpdate = true,
    int maxSeeds = 20,
  }) async {
    for (var seed = 0; seed < maxSeeds; seed++) {
      final scenario = await ScenarioRunner(
        surveyId: pkg.surveyId,
        respondent: VirtualRespondent(seed: seed),
        childrenToComplete: childrenToComplete,
        acceptCountUpdate: acceptCountUpdate,
      ).run('hh');
      if (scenario.repeats.isNotEmpty) return scenario;
    }
    return null;
  }

  test('a parent leads to its children, linked and numbered', () async {
    final scenario = await enrolledScenario();
    expect(scenario, isNotNull,
        reason: '20 seeds produced no household that starts a repeat loop');

    expect(scenario!.livelocked, isFalse);
    expect(scenario.children, isNotEmpty);

    final db = await DbService.getDatabaseForQueries(pkg.surveyId);
    final parentKey = scenario.parent.storedRow['hhid'];
    expect(parentKey, isNot('-9'));

    for (final repeat in scenario.repeats) {
      final rows = await db.query(repeat.childTable, where: 'hhid = ?', whereArgs: [parentKey]);
      expect(rows.length, repeat.entered,
          reason: '${repeat.childTable}: rows on disk should match what saved');

      for (final row in rows) {
        expect(row['parent_uniqueid'], scenario.parent.uniqueId,
            reason: '${repeat.childTable}: child not tied to its parent');
      }

      // The sibling ordinal is contiguous from 1. Nothing in the database
      // enforces this -- deliberately, since a failed insert would lose an
      // interview -- so this check is the only thing that would find a
      // counter bug.
      final ordinals = rows.map((r) => int.tryParse('${r['linenum']}') ?? -1).toList()..sort();
      expect(ordinals, List.generate(rows.length, (i) => i + 1),
          reason: '${repeat.childTable}.linenum should be 1..N');
    }
  });

  test('a follow-up entered by hand is done for every parent that qualifies,'
      ' with the linking value filled in', () async {
    final db = await DbService.getDatabaseForQueries(pkg.surveyId);
    var qualified = 0;
    var notQualified = 0;
    for (var seed = 0; seed < 12; seed++) {
      final scenario = await ScenarioRunner(
        surveyId: pkg.surveyId,
        respondent: VirtualRespondent(seed: seed),
      ).run('hh');
      final outcome = scenario.oneOffs.singleWhere((o) => o.childTable == 'followup');
      final enrolled = '${scenario.parent.storedRow['enrolled']}' == '1';
      expect(outcome.qualified, enrolled, reason: 'seed $seed: entry_condition enrolled=1');
      expect(outcome.entered, enrolled, reason: 'seed $seed: done exactly when qualified');
      if (!enrolled) {
        notQualified++;
        continue;
      }
      qualified++;
      final rows = await db.query('followup', where: 'hhid = ?', whereArgs: [scenario.parent.storedRow['hhid']]);
      expect(rows.length, 1, reason: 'one follow-up per qualifying parent');
      // `hhid` is automatic in the child: filled from the parent, not typed.
      expect(rows.single['hhid'], scenario.parent.storedRow['hhid']);
      expect(rows.single['parent_uniqueid'], scenario.parent.uniqueId);
    }
    expect(qualified, greaterThan(0));
    expect(notQualified, greaterThan(0), reason: 'both branches should occur in 12 seeds');
  });

  test('entering fewer children than declared reconciles the parent count',
      () async {
    // The fixture sets repeat_enforce_count=3 -- update silently.
    final scenario = await enrolledScenario(childrenToComplete: {'member': 1});
    expect(scenario, isNotNull);

    for (final repeat in scenario!.repeats) {
      if (repeat.entered == repeat.declared) continue;
      if (repeat.outcome == RepeatCountOutcome.belowMinimum ||
          repeat.outcome == RepeatCountOutcome.aboveMaximum) {
        continue;
      }
      expect(repeat.countAfter, repeat.entered,
          reason: 'mode 3 should have corrected ${repeat.countField} to what was entered');
    }
  });
}
