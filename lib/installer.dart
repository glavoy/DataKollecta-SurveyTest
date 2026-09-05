import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:datakollecta/services/app_paths.dart';
import 'package:datakollecta/services/db_service.dart';
import 'package:datakollecta/services/settings_service.dart';
import 'package:datakollecta/services/survey_config_service.dart';
import 'package:path/path.dart' as p;

/// What a package turned out to contain, once installed.
class InstalledPackage {
  const InstalledPackage({
    required this.surveyId,
    required this.surveyName,
    required this.databaseName,
    required this.xmlFiles,
    required this.crfs,
    required this.sourceZip,
    required this.surveyDir,
    required this.databaseFile,
  });

  final String surveyId;
  final String surveyName;
  final String databaseName;
  final List<String> xmlFiles;

  /// The manifest's `crfs` array, verbatim. This is what a designer's `crfs`
  /// worksheet actually became, which nothing else shows them.
  final List<Map<String, dynamic>> crfs;

  final File sourceZip;
  final Directory surveyDir;
  final File databaseFile;

  /// The base form, if the manifest declares one.
  Map<String, dynamic>? get baseCrf {
    for (final crf in crfs) {
      if (_asInt(crf['isbase']) == 1) return crf;
    }
    return null;
  }

  /// Forms that repeat after their parent is saved, in `display_order`.
  List<Map<String, dynamic>> get repeatingChildren {
    final children = crfs
        .where((c) => (c['parenttable']?.toString() ?? '').isNotEmpty)
        .toList();
    children.sort(
      (a, b) =>
          _asInt(a['display_order']).compareTo(_asInt(b['display_order'])),
    );
    return children;
  }

  static int _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0);
}

/// A package that could not be installed, with a reason worth reading.
class InstallException implements Exception {
  const InstallException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Installs a survey package from a zip anywhere on disk.
///
/// **The zip is opened with `readAsBytes` and never written, moved or
/// deleted.** A designer may keep it in a temp folder, next to the dictionary,
/// or anywhere else; this reads it and leaves it exactly as it found it.
///
/// `SurveyConfigService.initializeSurveys()` is deliberately not used, for two
/// reasons that are both wrong for this app and right for a device:
///
/// * it scans only the `zips/` folder, so the zip would have to be copied in
///   first -- a write this app has no business making;
/// * it extracts **only if the target folder does not already exist**, so the
///   second run after a designer regenerates their package would silently test
///   the *first* version. On a device that idempotence is correct: a package is
///   installed once and the app restarts to change it.
///
/// It also fixes a hazard by construction. `initializeSurveys` names the
/// extraction folder after the **zip filename**, while
/// `DbService._syncSurveyTable` looks for XML under `surveys/<surveyId>/`.
/// Those agree only because SurveyGen happens to name the zip after the
/// surveyId; rename the file and you get a populated `crfs` table, no data
/// tables at all, and nothing but a debug log to say so. Extracting by
/// `surveyId` read from the manifest makes the name of the file irrelevant.
class PackageInstaller {
  const PackageInstaller();

  static const String manifestName = 'survey_manifest.gistx';

  Future<InstalledPackage> install(
    File zipFile, {
    bool freshDatabase = true,
  }) async {
    if (!await zipFile.exists()) {
      throw InstallException('No file at ${zipFile.path}');
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    } catch (e) {
      throw InstallException(
        '${p.basename(zipFile.path)} is not a readable '
        'zip archive: $e',
      );
    }

    final manifest = _readManifest(archive, zipFile);
    final surveyId = _requireString(manifest, 'surveyId', zipFile);
    final surveyName = _requireString(manifest, 'surveyName', zipFile);
    final databaseName = _requireString(manifest, 'databaseName', zipFile);

    final surveysDir = await AppPaths.surveysDir(create: true);
    final target = Directory(p.join(surveysDir.path, surveyId));

    // Close before deleting: the previous install of this surveyId may still
    // hold the SQLite file open, and Windows refuses to unlink an open file.
    await DbService.closeSurvey(surveyId);

    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    await target.create(recursive: true);

    for (final entry in archive) {
      if (!entry.isFile) continue;
      final name = entry.name;
      // Same exclusions the field app applies, so a package that installs here
      // installs there.
      if (name.contains('__MACOSX') || p.basename(name).startsWith('.')) {
        continue;
      }
      final out = File(p.join(target.path, p.basename(name)));
      await out.writeAsBytes(entry.content as List<int>);
    }

    final databaseFile = File(
      p.join((await AppPaths.databasesDir()).path, databaseName),
    );
    if (freshDatabase && await databaseFile.exists()) {
      await databaseFile.delete();
    }

    // The manifest cache is keyed by file path and is never invalidated on
    // extraction, so without this the app would read the manifest it saw
    // before this zip replaced it.
    SurveyConfigService().clearCache();

    // `getActiveSurveyId()` matches on the survey *name*, not the id, even
    // though the setting is called `active_survey`.
    await SettingsService().setActiveSurvey(surveyName);

    await DbService.init();

    final resolved = await SurveyConfigService().getActiveSurveyId();
    if (resolved != surveyId) {
      throw InstallException(
        'Installed $surveyId but the app resolved the active survey as '
        '${resolved ?? 'nothing'}. Another package in the sandbox declares the '
        'same surveyName ("$surveyName"), so the two are indistinguishable.',
      );
    }

    return InstalledPackage(
      surveyId: surveyId,
      surveyName: surveyName,
      databaseName: databaseName,
      xmlFiles: (manifest['xmlFiles'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      crfs: (manifest['crfs'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(),
      sourceZip: zipFile,
      surveyDir: target,
      databaseFile: databaseFile,
    );
  }

  Map<String, dynamic> _readManifest(Archive archive, File zipFile) {
    for (final entry in archive) {
      if (entry.isFile && p.basename(entry.name) == manifestName) {
        try {
          return json.decode(utf8.decode(entry.content as List<int>))
              as Map<String, dynamic>;
        } catch (e) {
          throw InstallException(
            '$manifestName in '
            '${p.basename(zipFile.path)} is not valid JSON: $e',
          );
        }
      }
    }
    throw InstallException(
      '${p.basename(zipFile.path)} contains no $manifestName, so it is not a '
      'survey package. SurveyGen writes one into every zip it builds.',
    );
  }

  String _requireString(Map<String, dynamic> manifest, String key, File zip) {
    final value = manifest[key];
    if (value is String && value.isNotEmpty) return value;
    throw InstallException(
      'The manifest in ${p.basename(zip.path)} declares no "$key". Every '
      'package needs one; regenerate it with SurveyGen.',
    );
  }
}
