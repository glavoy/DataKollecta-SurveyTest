import 'dart:io';

import 'package:archive/archive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A survey package built from files checked into `test/fixtures/`.
///
/// Every other test file here reaches for a real study zip at an absolute path
/// under `/Users/glavoy/temp` and calls `markTestSkipped` when it is not
/// there, so on any machine but one the suite passes while asserting almost
/// nothing. Real dictionaries belong to studies rather than to this repo and
/// `.gitignore` excludes `*.zip` deliberately -- so the fixture is stored as
/// its loose parts and zipped into the test's own temp directory here.
File buildFixtureZip(String name, Directory into) {
  final source = Directory(p.join('test', 'fixtures', name));
  if (!source.existsSync()) {
    throw StateError('No fixture at ${source.path}');
  }

  final archive = Archive();
  for (final entry in source.listSync().whereType<File>()) {
    final bytes = entry.readAsBytesSync();
    archive.addFile(ArchiveFile(p.basename(entry.path), bytes.length, bytes));
  }

  final zip = File(p.join(into.path, '$name.zip'));
  zip.writeAsBytesSync(ZipEncoder().encode(archive)!);
  return zip;
}

/// The plugin mocks and FFI init every test file in this package repeats.
void initTestEnvironment() {
  SharedPreferences.setMockInitialValues({});
  PackageInfo.setMockInitialValues(
    appName: 'surveytest',
    packageName: 'com.datakollecta.surveytest',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );
  sqfliteFfiInit();
}
