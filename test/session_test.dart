import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:surveytest/installer.dart';
import 'package:surveytest/sandbox.dart';
import 'package:surveytest/sim/session.dart';

File? findPackage() {
  final f = File('/Users/glavoy/temp/prism_css_test_2026_08_23.zip');
  return f.existsSync() ? f : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

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
    root = await Directory.systemTemp.createTemp('surveytest_session');
    await Sandbox.install(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a batch of interviews reports coverage and any findings', () async {
    final zip = findPackage();
    if (zip == null) {
      markTestSkipped('No PRISM package available.');
      return;
    }

    final pkg = await const PackageInstaller().install(zip);
    final session = SimulationSession(pkg);

    var lastDone = 0;
    final report = await session.run(
      const RunSettings(runs: 25, seed: 20260905),
      onProgress: (done, total) => lastDone = done,
    );

    expect(lastDone, 25, reason: 'progress should reach the end');
    expect(report.runs, 25);
    expect(report.records, greaterThanOrEqualTo(25));
    expect(report.questionsSeen, isNotEmpty);

    // The database really holds what the report counted.
    final counts = await session.recordCounts();
    expect(counts['hh_info'], 25);

    // Every finding names a seed, or it cannot be reproduced.
    for (final finding in report.findings) {
      expect(finding.seed, isNotNull, reason: '${finding.code} has no seed');
    }

    // Print the summary a designer would read, so a regression in what the
    // app reports is visible in the test log rather than only in the UI.
    // ignore: avoid_print
    print('findings=${report.findings.length} '
        'questionsSeen=${report.questionsSeen.length} '
        'neverAnswered=${report.neverAnswered.length} '
        'repeatCells=${report.repeatCells} '
        'unanswerable=${report.unanswerable.keys.take(5).toList()}');
    for (final f in report.findings.take(6)) {
      // ignore: avoid_print
      print('  ${f.where}  ${f.code}  ${f.detail}');
    }
  });

  test('the same seed produces the same findings', () async {
    final zip = findPackage();
    if (zip == null) {
      markTestSkipped('No PRISM package available.');
      return;
    }

    Future<List<String>> findingsFor() async {
      final pkg = await const PackageInstaller().install(zip);
      final report = await SimulationSession(pkg)
          .run(const RunSettings(runs: 8, seed: 99));
      return report.findings.map((f) => '${f.where}:${f.code}').toList();
    }

    expect(await findingsFor(), await findingsFor(),
        reason: 'a report that cannot be reproduced cannot be acted on');
  });
}
