import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../installer.dart';
import '../reporting/html_report.dart';
import '../sandbox.dart';
import '../sim/report.dart';
import '../sim/session.dart';
import 'package_view.dart';
import 'report_view.dart';
import 'run_view.dart';

/// The whole app: choose a package, run interviews against it, read what broke.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.sandbox});

  final Sandbox sandbox;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  InstalledPackage? _package;
  RunReport? _report;
  File? _reportFile;
  String? _error;
  bool _busy = false;
  int _done = 0;
  int _total = 0;

  Future<void> _choosePackage() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a survey package',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    await _install(File(path));
  }

  Future<void> _install(File zip) async {
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
    });
    try {
      final installed = await const PackageInstaller().install(zip);
      setState(() {
        _package = installed;
        _reportFile = null;
      });
    } on InstallException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _run(RunSettings settings) async {
    final package = _package;
    if (package == null) return;

    setState(() {
      _busy = true;
      _error = null;
      _report = null;
      _reportFile = null;
      _done = 0;
      _total = settings.runs;
    });

    try {
      // Reinstall first, so every run starts from an empty database and the
      // increment and id counters begin where a fresh device would.
      final reinstalled = await const PackageInstaller().install(
        package.sourceZip,
      );
      final report = await SimulationSession(reinstalled).run(
        settings,
        onProgress: (done, total) => setState(() {
          _done = done;
          _total = total;
        }),
      );
      final reportFile = await _writeReport(report, reinstalled);
      setState(() {
        _package = reinstalled;
        _report = report;
        _reportFile = reportFile;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Writes every run's report to disk automatically, so findings survive
  /// after the window closes without needing a save step.
  Future<File> _writeReport(RunReport report, InstalledPackage package) async {
    final dir = Directory(p.join(widget.sandbox.root.path, 'reports'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final file = File(p.join(dir.path, '${package.surveyId}_$stamp.html'));
    await file.writeAsString(buildHtmlReport(report, package));
    return file;
  }

  @override
  Widget build(BuildContext context) {
    final package = _package;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Survey Test'),
        actions: [
          if (package != null)
            TextButton.icon(
              onPressed: _busy ? null : _choosePackage,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose another'),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy && _total > 0)
            LinearProgressIndicator(value: _total == 0 ? null : _done / _total)
          else if (_busy)
            const LinearProgressIndicator(),
          if (_error != null) _ErrorBanner(message: _error!),
          Expanded(
            child: package == null
                ? _Welcome(onChoose: _busy ? null : _choosePackage)
                : ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      PackageView(package: package, sandbox: widget.sandbox),
                      const SizedBox(height: 20),
                      RunView(
                        busy: _busy,
                        done: _done,
                        total: _total,
                        onRun: _run,
                      ),
                      if (_report != null) ...[
                        const SizedBox(height: 20),
                        ReportView(report: _report!, package: package),
                        if (_reportFile != null) ...[
                          const SizedBox(height: 8),
                          _ReportFileNote(file: _reportFile!),
                        ],
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onChoose});

  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.science_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 20),
            Text(
              'Test a survey package',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Choose a .zip built by SurveyGen. This runs simulated '
              'interviews against it using the same engine the field app '
              'uses, and reports anything that went wrong.\n\n'
              'The zip is only read. It is never changed.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onChoose,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose a package'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportFileNote extends StatelessWidget {
  const _ReportFileNote({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.description_outlined, size: 16, color: theme.colorScheme.outline),
        const SizedBox(width: 6),
        Expanded(
          child: SelectableText(
            'Report saved to ${file.path}',
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (Platform.isMacOS)
          TextButton(
            onPressed: () => Process.run('open', [file.path]),
            child: const Text('Open'),
          ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
