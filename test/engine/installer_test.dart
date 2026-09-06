import 'dart:io';

import 'package:datakollecta/services/db_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:surveytest/installer.dart';
import 'package:surveytest/sandbox.dart';

import '../support/fixture_package.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    initTestEnvironment();
    root = await Directory.systemTemp.createTemp('surveytest_install');
    await Sandbox.install(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('installs a package and creates its tables', () async {
    final zip = buildFixtureZip('household_repeat', root);
    final before = zip.statSync();
    final installed = await const PackageInstaller().install(zip);

    // Extracted by surveyId, not by the zip's filename -- which is what keeps
    // DbService able to find the XML.
    expect(p.basename(installed.surveyDir.path), installed.surveyId);
    expect(File(p.join(installed.surveyDir.path, 'survey_manifest.gistx')).existsSync(), isTrue);

    final db = await DbService.getDatabaseForQueries(installed.surveyId);
    final tables = (await db.query('sqlite_master', columns: ['name'], where: 'type = ?', whereArgs: ['table']))
        .map((r) => r['name'] as String)
        .toSet();

    expect(tables, containsAll(['crfs', 'formchanges', 'hh', 'member', 'followup']));
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
      throwsA(isA<InstallException>().having((e) => e.message, 'message', contains('survey_manifest.gistx'))),
    );
  });

  test('reinstalling in one process picks up the new package', () async {
    final zip = buildFixtureZip('household_repeat', root);
    final first = await const PackageInstaller().install(zip);
    final db = await DbService.getDatabaseForQueries(first.surveyId);
    await db.insert('hh', {'uniqueid': 'left-over'});

    final second = await const PackageInstaller().install(zip);
    final reopened = await DbService.getDatabaseForQueries(second.surveyId);
    expect((await reopened.query('hh')).length, 0,
        reason: 'the second install reused the first run\'s database');
  });
}
