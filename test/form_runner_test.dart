import 'dart:io';

import 'package:datakollecta/services/db_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:surveytest/installer.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/form_runner.dart';
import 'package:surveytest/sim/virtual_respondent.dart';

File? findPackage() {
  for (final candidate in [
    '/Users/glavoy/temp/prism_css_test_2026_08_23.zip',
    p.join(
      Directory.current.parent.path,
      'DataKollecta',
      'zips',
      'avert_ug_test_2026_08_11.zip',
    ),
  ]) {
    final f = File(candidate);
    if (f.existsSync()) return f;
  }
  return null;
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
    root = await Directory.systemTemp.createTemp('surveytest_run');
    await Sandbox.install(root);
    final zip = findPackage();
    if (zip == null) return;
    pkg = await const PackageInstaller().install(zip);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'completes an interview on the base form and stores the answers',
    () async {
      if (findPackage() == null) {
        markTestSkipped('No survey package available.');
        return;
      }

      final base = pkg.baseCrf!;
      final table = base['tablename'] as String;

      final run = await FormRunner(
        surveyId: pkg.surveyId,
        tableName: table,
        respondent: VirtualRespondent(
          seed: 1,
          strategy: RespondentStrategy.random,
        ),
      ).run();

      expect(run.saveError, isNull, reason: 'the interview did not save');
      expect(run.route, isNotEmpty, reason: 'navigation reached no question');
      expect(run.uniqueId, isNotNull);

      // The row is really in the database, with the answers that were given.
      final db = await DbService.getDatabaseForQueries(pkg.surveyId);
      final rows = await db.query(table);
      expect(rows.length, 1);

      final stored = rows.single;
      expect(stored['uniqueid'], run.uniqueId);
      expect(stored['starttime'], isNotNull);
      expect(stored['stoptime'], isNotNull);
      expect(stored['survey_id'], isNotNull);

      // Every answer that was given survived into the row.
      for (final entry in run.storedRow.entries) {
        if (entry.value == null) continue;
        if (!stored.containsKey(entry.key)) continue;
        expect(
          '${stored[entry.key]}',
          '${entry.value}',
          reason: '${entry.key} was stored differently from what was answered',
        );
      }
    },
  );

  test('the same seed produces the same route', () async {
    if (findPackage() == null) {
      markTestSkipped('No survey package available.');
      return;
    }
    final base = pkg.baseCrf!;
    final table = base['tablename'] as String;

    Future<List<String>> routeFor(int seed) async => (await FormRunner(
      surveyId: pkg.surveyId,
      tableName: table,
      respondent: VirtualRespondent(seed: seed),
    ).run()).route;

    expect(
      await routeFor(4242),
      await routeFor(4242),
      reason: 'a seed must replay exactly, or a failure cannot be reproduced',
    );
  });

  test('the fuzz actually explores the form rather than one route', () async {
    if (findPackage() == null) {
      markTestSkipped('No survey package available.');
      return;
    }
    final table = pkg.baseCrf!['tablename'] as String;

    // Not "strategy A is longer than strategy B": PRISM guards the same field
    // from both sides (`if enrolled = 1, skip to swater` and `if enrolled = 0,
    // skip to totvisit`), so exactly one rule fires whichever answer is given
    // and neither strategy can lengthen the route. What matters is that a run
    // of seeds reaches more than one shape of interview -- a fuzz that always
    // walked the same path would pass every check and prove nothing.
    final routes = <String>{};
    for (var seed = 0; seed < 6; seed++) {
      final run = await FormRunner(
        surveyId: pkg.surveyId,
        tableName: table,
        respondent: VirtualRespondent(seed: seed),
      ).run();
      routes.add(run.route.join('>'));
    }

    expect(
      routes.length,
      greaterThan(1),
      reason: 'six seeds produced one route; the form is not being explored',
    );
  });

  test('generates a real subject ID rather than the -9 fallback', () async {
    if (findPackage() == null) {
      markTestSkipped('No survey package available.');
      return;
    }
    final base = pkg.baseCrf!;
    final table = base['tablename'] as String;
    final key = (base['primarykey'] as String).split(',').first.trim();

    final run = await FormRunner(
      surveyId: pkg.surveyId,
      tableName: table,
      respondent: VirtualRespondent(seed: 11),
    ).run();

    expect(
      run.storedRow[key],
      isNot('-9'),
      reason: 'the idconfig exists to build $key; -9 is the failure value',
    );
    expect(run.storedRow[key], isNotNull);
  });
}
