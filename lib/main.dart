import 'dart:io';

import 'package:datakollecta/services/db_service.dart';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sandbox.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Before anything else touches a path. The engine is compiled from
  // package:datakollecta and inherits its storage folder, so without this the
  // app would install packages and write records into a real GiSTX
  // installation on the same machine.
  final sandbox = await Sandbox.installDefault();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
  }
  await DbService.init();

  runApp(SurveyTestApp(sandbox: sandbox));
}

class SurveyTestApp extends StatelessWidget {
  const SurveyTestApp({super.key, required this.sandbox});

  final Sandbox sandbox;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Survey Test',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00695C)),
        useMaterial3: true,
      ),
      home: HomeScreen(sandbox: sandbox),
    );
  }
}
