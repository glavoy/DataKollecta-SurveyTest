import 'dart:io';

import 'package:datakollecta/services/app_paths.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Keeps this app's files away from the field app's.
///
/// The engine is compiled from `package:datakollecta`, so it inherits
/// `AppConfig.storageFolder` -- which is `GiSTX`, because `APP_PRODUCT` is not
/// set for this build. Without a redirect this app would install packages and
/// write records into whatever real GiSTX installation is on the same machine.
///
/// [AppPaths.overrideBaseDir] exists for exactly this. Setting it before
/// anything reads a path moves the whole tree:
///
///     <sandboxRoot>/GiSTX/zips
///                        /surveys/<surveyId>
///                        /databases/<databaseName>
///
/// The `GiSTX` segment is deliberate rather than a wart. The point of this app
/// is to reproduce what a device does, and under a root nobody else knows about
/// the name carries no meaning. `swver` on every simulated record reads
/// `GiSTX <version>` for the same reason: it is the value the field app would
/// have written.
class Sandbox {
  const Sandbox(this.root);

  final Directory root;

  /// `<application support>/SurveyTest` -- resolved before the redirect is
  /// installed, so it is the real per-user location and not a path inside
  /// itself.
  static Future<Directory> defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'SurveyTest'));
  }

  /// Points the engine at [root]. Call before anything else touches a path.
  static Future<Sandbox> install(Directory root) async {
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    AppPaths.overrideBaseDir = root;
    return Sandbox(root);
  }

  static Future<Sandbox> installDefault() async => install(await defaultRoot());

  /// True when the engine is actually redirected here. Read by the UI so a
  /// designer is told plainly rather than discovering it from where the data
  /// went.
  bool get isActive => AppPaths.overrideBaseDir?.path == root.path;

  Future<Directory> get surveysDir => AppPaths.surveysDir();
  Future<Directory> get databasesDir => AppPaths.databasesDir();

  /// Everything this app has ever written. Deleting it loses only test data.
  Future<void> reset() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
    await root.create(recursive: true);
  }
}
