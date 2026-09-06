import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/logic_tally.dart';

import '../support/fixture_package.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    initTestEnvironment();
    root = await Directory.systemTemp.createTemp('surveytest_logic');
    await Sandbox.install(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('identifiers are the fields a condition names, nothing else', () {
    expect(
      LogicTally.identifiersIn("age < 18 and (sex = 1 or name contains 'and')"),
      {'age', 'sex', 'name'},
    );
  });

  test('a check whose operand every route has skipped is inert', () async {
    final report = await runFixture('logic_inert', root, runs: 20);

    final tally = report.logicChecks.keys.singleWhere((k) => k.contains('q5.logic[0]'));
    expect(report.logicChecks[tally]!.evaluated, greaterThan(0));
    expect(report.logicChecks[tally]!.fired, 0);
    expect(report.logicNeverFired, contains(tally));

    final inert = report.findings.singleWhere((f) => f.code == 'logic_check_inert');
    expect(inert.field, startsWith('q5.logic[0]'));
    expect(inert.detail, contains('q2 was blank'));
    expect(inert.detail, contains('consent.postskip[0]'));
  });

  test('a check that fires and passes on its merits is not inert', () async {
    // `trap_logic`'s check on age fires every time; nothing about it is
    // inert, and the report must not say otherwise.
    final report = await runFixture('trap_logic', root, runs: 3);
    expect(report.findings.where((f) => f.code == 'logic_check_inert'), isEmpty);
    final tally = report.logicChecks.values.single;
    expect(tally.fired, greaterThan(0));
    expect(tally.nullOperand, 0);
  });
}
