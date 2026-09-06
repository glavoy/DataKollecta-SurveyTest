import 'dart:io';

import 'package:datakollecta/services/db_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surveytest/installer.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/form_runner.dart';
import 'package:surveytest/sim/virtual_respondent.dart';

import '../support/fixture_package.dart';

/// Harness self-tests: `FormRunner` drives the real engine and leaves behind
/// what the field app would. Nothing here is about a dictionary; it is about
/// the runner mirroring the widget layer faithfully enough that the design
/// findings built on top of it can be trusted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late InstalledPackage pkg;

  setUp(() async {
    initTestEnvironment();
    root = await Directory.systemTemp.createTemp('surveytest_run');
    await Sandbox.install(root);
    pkg = await installFixture('household_repeat', root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('completes an interview on the base form and stores the answers',
      () async {
    final run = await FormRunner(
      surveyId: pkg.surveyId,
      tableName: 'hh',
      respondent: VirtualRespondent(seed: 1),
    ).run();

    expect(run.saveError, isNull, reason: 'the interview did not save');
    expect(run.route, isNotEmpty, reason: 'navigation reached no question');
    expect(run.uniqueId, isNotNull);
    expect(run.hops.first.from, Hop.start);
    expect(run.hops.last.to, Hop.end);

    final db = await DbService.getDatabaseForQueries(pkg.surveyId);
    final rows = await db.query('hh');
    expect(rows.length, 1);

    final stored = rows.single;
    expect(stored['uniqueid'], run.uniqueId);
    expect(stored['starttime'], isNotNull);
    expect(stored['stoptime'], isNotNull);
    expect(stored['survey_id'], isNotNull);

    for (final entry in run.storedRow.entries) {
      if (entry.value == null) continue;
      if (!stored.containsKey(entry.key)) continue;
      expect(
        '${stored[entry.key]}',
        '${entry.value}',
        reason: '${entry.key} was stored differently from what was answered',
      );
    }
  });

  test('the same seed produces the same route', () async {
    Future<List<String>> routeFor(int seed) async {
      final fresh = await const PackageInstaller().install(pkg.sourceZip);
      return (await FormRunner(
        surveyId: fresh.surveyId,
        tableName: 'hh',
        respondent: VirtualRespondent(seed: seed),
      ).run())
          .route;
    }

    expect(await routeFor(4242), await routeFor(4242),
        reason: 'a seed must replay exactly, or a failure cannot be reproduced');
  });

  test('the fuzz actually explores the form rather than one route', () async {
    final routes = <String>{};
    for (var seed = 0; seed < 8; seed++) {
      final run = await FormRunner(
        surveyId: pkg.surveyId,
        tableName: 'hh',
        respondent: VirtualRespondent(seed: seed),
      ).run();
      routes.add(run.route.join('>'));
    }
    expect(routes.length, greaterThan(1),
        reason: 'eight seeds produced one route; the form is not being explored');
  });

  test('generates a real subject ID rather than the -9 fallback', () async {
    final run = await FormRunner(
      surveyId: pkg.surveyId,
      tableName: 'hh',
      respondent: VirtualRespondent(seed: 11),
    ).run();

    expect(run.storedRow['hhid'], isNot('-9'),
        reason: 'the idconfig exists to build hhid; -9 is the failure value');
    expect(run.storedRow['hhid'], matches(RegExp(r'^\d{4}$')));
  });

  group('a valid query calculation', () {
    late Directory queryRoot;
    late InstalledPackage queryPkg;

    setUp(() async {
      queryRoot = await Directory.systemTemp.createTemp('surveytest_run');
      await Sandbox.install(queryRoot);
      queryPkg = await installFixture('query_calc_lookup', queryRoot);
    });

    tearDown(() async {
      if (await queryRoot.exists()) await queryRoot.delete(recursive: true);
    });

    test('still computes, rather than swallowing a failed lookup as \'\'',
        () async {
      final run = await FormRunner(
        surveyId: queryPkg.surveyId,
        tableName: 'form',
        respondent: VirtualRespondent(
          seed: 1,
          strategy: RespondentStrategy.firstOption,
        ),
      ).run();

      expect(run.saveError, isNull, reason: 'the interview did not save');
      expect(run.storedRow['lookup_code'], 'A1',
          reason: 'firstOption is expected to pick the first response');
      expect(run.storedRow['looked_up_name'], 'Alpha',
          reason: 'AutoFields swallows a failed query and returns \'\'; '
              'a run that merely completes proves nothing');

      final db = await DbService.getDatabaseForQueries(queryPkg.surveyId);
      final rows = await db.query('form');
      expect(rows.length, 1);
      expect(rows.single['looked_up_name'], 'Alpha',
          reason: 'the saved row must carry the looked-up value');
    });
  });
}
