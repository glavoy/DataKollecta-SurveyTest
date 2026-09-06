import 'dart:io';

import 'package:archive/archive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:surveytest/installer.dart';
import 'package:surveytest/sim/report.dart';
import 'package:surveytest/sim/session.dart';
import 'package:surveytest/sim/virtual_respondent.dart';

/// A survey package built from files checked into `test/fixtures/`.
///
/// Real dictionaries belong to studies rather than to this repo and
/// `.gitignore` excludes `*.zip` deliberately -- so every fixture is stored as
/// its loose parts (form XML, `survey_manifest.gistx`, any small CSV) and
/// zipped into the test's own temp directory here. Each fixture exists to trip
/// one class of finding and nothing else; `test/fixtures/README.md` lists
/// which, and `fixture_inventory_test.dart` holds it to that.
File buildFixtureZip(String name, Directory into) {
  final source = Directory(p.join('test', 'fixtures', name));
  if (!source.existsSync()) {
    throw StateError('No fixture at ${source.path}');
  }

  final archive = Archive();
  for (final entry in source.listSync().whereType<File>()) {
    if (p.basename(entry.path).startsWith('.')) continue;
    final bytes = entry.readAsBytesSync();
    archive.addFile(ArchiveFile(p.basename(entry.path), bytes.length, bytes));
  }

  final zip = File(p.join(into.path, '$name.zip'));
  zip.writeAsBytesSync(ZipEncoder().encode(archive)!);
  return zip;
}

/// Zips and installs a fixture into the sandbox rooted at [root].
Future<InstalledPackage> installFixture(String name, Directory root) =>
    const PackageInstaller().install(buildFixtureZip(name, root));

/// Installs a fixture and runs a batch of interviews against it.
///
/// The defaults are chosen for determinism, not realism: a fixed seed, and
/// the full strategy rotation so any code path a strategy exists for is
/// exercised on even a small batch.
Future<RunReport> runFixture(
  String name,
  Directory root, {
  int runs = 20,
  int seed = 20260905,
  bool steer = true,
  List<RespondentStrategy>? strategies,
  bool engineChecks = true,
}) async {
  final pkg = await installFixture(name, root);
  return SimulationSession(pkg).run(
    RunSettings(
      runs: runs,
      seed: seed,
      steer: steer,
      strategies: strategies ?? const RunSettings().strategies,
      engineChecks: engineChecks,
    ),
  );
}

/// Every fixture directory name under `test/fixtures/`.
List<String> fixtureNames() => Directory(p.join('test', 'fixtures'))
    .listSync()
    .whereType<Directory>()
    .map((d) => p.basename(d.path))
    .toList()
  ..sort();

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
