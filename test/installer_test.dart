import 'dart:io';

import 'package:datakollecta/services/db_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:surveytest/installer.dart';
import 'package:surveytest/sandbox.dart';

/// A real package built by SurveyGen from a real study. Not in the repo -- no
/// dictionary is -- so the suite skips with a message rather than failing when
/// it is absent.
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
    final file = File(candidate);
    if (file.existsSync()) return file;
  }
  return null;
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
    root = await Directory.systemTemp.createTemp('surveytest_install');
    await Sandbox.install(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('installs a real package and creates its tables', () async {
    final zip = findPackage();
    if (zip == null) {
      markTestSkipped('No survey package found to install.');
      return;
    }

    final before = zip.statSync();
    final installed = await const PackageInstaller().install(zip);

    // Extracted by surveyId, not by the zip's filename -- which is what keeps
    // DbService able to find the XML.
    expect(p.basename(installed.surveyDir.path), installed.surveyId);
    expect(
      File(
        p.join(installed.surveyDir.path, 'survey_manifest.gistx'),
      ).existsSync(),
      isTrue,
    );

    // Every form the manifest declares became a real table with real columns.
    final db = await DbService.getDatabaseForQueries(installed.surveyId);
    final tables = (await db.query(
      'sqlite_master',
      columns: ['name'],
      where: 'type = ?',
      whereArgs: ['table'],
    )).map((r) => r['name'] as String).toSet();

    expect(tables, contains('crfs'));
    expect(tables, contains('formchanges'));
    for (final xml in installed.xmlFiles) {
      expect(
        tables,
        contains(p.basenameWithoutExtension(xml).toLowerCase()),
        reason: '$xml produced no table',
      );
    }

    // The crfs table is populated, not merely created.
    expect((await db.query('crfs')).length, installed.crfs.length);

    // And the source zip is exactly as we found it.
    final after = zip.statSync();
    expect(after.modified, before.modified);
    expect(after.size, before.size);
  });

  test('a zip with no manifest is refused by name', () async {
    final notAPackage = File(p.join(root.path, 'notapackage.zip'))
      ..writeAsBytesSync([0x50, 0x4b, 0x05, 0x06, ...List.filled(18, 0)]);

    expect(
      () => const PackageInstaller().install(notAPackage),
      throwsA(
        isA<InstallException>().having(
          (e) => e.message,
          'message',
          contains('survey_manifest.gistx'),
        ),
      ),
    );
  });

  test('reinstalling in one process picks up the new package', () async {
    final zip = findPackage();
    if (zip == null) {
      markTestSkipped('No survey package found to install.');
      return;
    }

    final first = await const PackageInstaller().install(zip);
    // A record that must not survive a fresh install.
    final db = await DbService.getDatabaseForQueries(first.surveyId);
    final table = p
        .basenameWithoutExtension(first.xmlFiles.first)
        .toLowerCase();
    await db.insert(table, {'uniqueid': 'left-over'});

    final second = await const PackageInstaller().install(zip);
    final reopened = await DbService.getDatabaseForQueries(second.surveyId);
    expect(
      (await reopened.query(table)).length,
      0,
      reason: 'the second install reused the first run\'s database',
    );
  });
}
