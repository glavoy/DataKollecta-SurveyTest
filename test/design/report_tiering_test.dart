import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:surveytest/installer.dart';
import 'package:surveytest/reporting/html_report.dart';
import 'package:surveytest/sim/report.dart';

/// Design findings are the designer's; engine findings are the app
/// developer's. The report keeps them apart so a clean dictionary is not
/// read as dirty because of something the dictionary did not cause.
void main() {
  Finding f(String code, {String? field}) =>
      Finding(code: code, table: 't', field: field, detail: 'detail 1', seed: 1);

  RunReport build(List<Finding> findings) {
    final builder = ReportBuilder();
    for (final finding in findings) {
      builder.add(finding);
    }
    return builder.build();
  }

  test('every code has a tier, and the two sets are disjoint', () {
    expect(tierOf('answer_changed'), FindingTier.engine);
    expect(tierOf('duplicate_primary_key'), FindingTier.engine);
    expect(tierOf('question_never_reached'), FindingTier.design);
    expect(tierOf('skip_domain_gap'), FindingTier.design);
    expect(tierOf('some_future_code'), FindingTier.design,
        reason: 'unknown codes default to the designer, who is the audience');
  });

  test('groups sort design first, then by read-me-first rank', () {
    final report = build([
      f('answer_changed', field: 'a'),
      f('skip_rule_never_fired', field: 'r'),
      f('question_never_reached', field: 'q'),
      f('save_failed'),
      f('skip_domain_gap', field: 'g'),
    ]);
    expect(
      report.groupedFindings.map((g) => g.code).toList(),
      [
        'question_never_reached',
        'skip_domain_gap',
        'skip_rule_never_fired',
        'save_failed',
        'answer_changed',
      ],
    );
    expect(report.designGroups.map((g) => g.code), ['question_never_reached', 'skip_domain_gap', 'skip_rule_never_fired']);
    expect(report.engineGroups.map((g) => g.code), ['save_failed', 'answer_changed']);
  });

  test('a report with only engine findings is design-clean, not clean', () {
    final report = build([f('answer_changed', field: 'a')]);
    expect(report.clean, isFalse);
    expect(report.designClean, isTrue);
  });

  test('the html puts design problems in the open and engine problems in a details block', () {
    final report = build([
      f('question_never_reached', field: 'q'),
      f('answer_changed', field: 'a'),
    ]);
    final pkg = InstalledPackage(
      surveyId: 'x',
      surveyName: 'X',
      databaseName: 'x.sqlite',
      xmlFiles: const [],
      crfs: const [],
      sourceZip: File('x.zip'),
      surveyDir: Directory('x'),
      databaseFile: File('x.sqlite'),
    );
    final html = buildHtmlReport(report, pkg);
    final design = html.indexOf('<h2>Design problems</h2>');
    final engine = html.indexOf('<details class="engine">');
    expect(design, greaterThan(0));
    expect(engine, greaterThan(design));
    expect(html.indexOf('question_never_reached'), lessThan(engine));
    expect(html.indexOf('answer_changed'), greaterThan(engine));
    expect(html, contains('1 design problem(s)'));
  });
}
