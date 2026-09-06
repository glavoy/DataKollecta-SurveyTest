import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/decision_table.dart';
import 'package:surveytest/sim/form_runner.dart';
import 'package:surveytest/sim/skip_topology.dart';
import 'package:surveytest/sim/virtual_respondent.dart';
import 'package:datakollecta/services/survey_loader.dart';

import '../support/fixture_package.dart';

/// The decision table is what a designer reads against the paper
/// questionnaire: after this answer, which question came next; and under
/// which answers was this question shown or skipped.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    initTestEnvironment();
    root = await Directory.systemTemp.createTemp('surveytest_decisions');
    await Sandbox.install(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('records where each answer led and what was skipped on the way',
      () async {
    final report = await runFixture('malaria_screening', root, runs: 30);
    final table = report.decisions['malaria_screening']!;

    // Table A: after `sex`, a man jumps to `treatment`; a woman carries on
    // to `age_years` (and is sent past `symptoms` only when she gets there).
    final afterSex = table.nextAfter['sex']!;
    expect(afterSex.counts['1']!.keys, ['treatment']);
    expect(afterSex.counts['2']!.keys, ['age_years']);

    // Table B: `symptoms` was never shown under either value, and the engine
    // named the rule that did it each time.
    final symptoms = table.gatingWhen['symptoms']!;
    for (final row in symptoms.values) {
      expect(row.shown, 0);
      expect(row.skipped, greaterThan(0));
      expect(row.skippedByRule, isNotEmpty);
    }
    expect(
      symptoms['sex=1']!.skippedByRule.keys.single,
      startsWith('malaria_screening.sex.postskip[0]'),
    );
    expect(
      symptoms['sex=2']!.skippedByRule.keys.single,
      startsWith('malaria_screening.symptoms.preskip[0]'),
    );
  });

  test('a terminal information screen that is fallen through is a finding',
      () async {
    final report = await runFixture('info_fallthrough', root, runs: 20);
    final table = report.decisions['screening']!;

    expect(table.informationScreens, {'not_eligible'});
    expect(table.fallThrough['not_eligible'], greaterThan(0));

    final finding = report.findings.singleWhere(
      (f) => f.code == 'information_screen_fell_through',
    );
    expect(finding.field, 'not_eligible');

    // An information screen stores nothing, so it is never "unanswered";
    // and its postskip firing on every display is the screen working.
    expect(report.informationQuestions, contains('not_eligible'));
    expect(report.neverAnswered, isNot(contains('not_eligible')));
    expect(
      report.findings.where((f) =>
          f.code == 'skip_rule_always_fired' && f.field!.startsWith('not_eligible.postskip')),
      isEmpty,
    );
    // The detail names what the tested field held when it happened: the
    // Don't-know code neither rule covers.
    expect(finding.detail, contains('eligible=-7'));
  });

  test('attribution rules, on hand-built hops', () async {
    final questions = await SurveyLoader.loadFromFile(
      File('test/fixtures/malaria_screening/malaria_screening.xml'),
    );
    final topology = SkipTopology.of('malaria_screening', questions);
    final builder = DecisionTableBuilder(topology);
    final postskip = topology.rules.singleWhere((r) => r.owner == 'sex');

    builder.observe(
      FormRun(
        tableName: 'malaria_screening',
        answers: const {},
        storedRow: const {},
        visitedFields: const {},
        route: const ['sex', 'treatment'],
        hops: [
          Hop(
            from: 'sex',
            to: 'treatment',
            fromValue: '1',
            firedRuleIds: [postskip.id],
            evaluatedRuleIds: [postskip.id],
            gating: const {'sex': '1'},
            fellThrough: false,
          ),
        ],
        postskipFallThroughs: const {},
        logicTallies: const {},
        decisions: const <Decision>[],
        uniqueId: null,
        blockedBy: const [],
        unanswerable: const [],
        cannotAdvance: const [],
        deadEndRoutes: const [],
        saveError: null,
      ),
    );
    final table = builder.build();

    expect(table.nextAfter['sex']!.counts, {'1': {'treatment': 1}});
    // Everything between `sex` and `treatment` was skipped, by that rule.
    for (final q in ['age_years', 'fever48h', 'symptoms', 'rdt_result']) {
      final row = table.gatingWhen[q]?['sex=1'];
      expect(row?.skipped, 1, reason: q);
      expect(row?.skippedByRule, {postskip.id: 1}, reason: q);
    }
    // `treatment` was shown -- and `sex` does gate it, because the
    // `symptoms.preskip[0] sex = 2 -> comments` rule jumps over it.
    expect(table.gatingWhen['treatment']!['sex=1']!.shown, 1);
    // `comments` is jumped over by nothing, so nothing gates it.
    expect(table.gatingWhen['comments'], isNull);
  });
}
