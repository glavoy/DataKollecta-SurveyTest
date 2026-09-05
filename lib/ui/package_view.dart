import 'dart:io';

import 'package:flutter/material.dart';

import '../installer.dart';
import '../sandbox.dart';

/// What the package turned out to contain.
///
/// The crfs columns are shown because nothing else shows a designer what their
/// crfs worksheet actually became -- `auto_start_repeat` and
/// `repeat_enforce_count` in particular, which decide how many child records
/// get entered and what happens to the parent's count when they do not match.
class PackageView extends StatelessWidget {
  const PackageView({super.key, required this.package, required this.sandbox});

  final InstalledPackage package;
  final Sandbox sandbox;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(package.surveyName, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            SelectableText(
              package.sourceZip.path,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                _Fact('Survey id', package.surveyId),
                _Fact('Database', package.databaseName),
                _Fact('Forms', '${package.crfs.length}'),
              ],
            ),
            const SizedBox(height: 20),
            Text('Forms', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _CrfTable(crfs: package.crfs),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Data is written to ${sandbox.root.path}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _reveal(sandbox.root.path),
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  label: const Text('Reveal'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static void _reveal(String path) {
    if (Platform.isMacOS) {
      Process.run('open', [path]);
    } else if (Platform.isWindows) {
      Process.run('explorer', [path]);
    } else {
      Process.run('xdg-open', [path]);
    }
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        SelectableText(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _CrfTable extends StatelessWidget {
  const _CrfTable({required this.crfs});

  final List<Map<String, dynamic>> crfs;

  static String _cell(Map<String, dynamic> crf, String key) {
    final value = crf[key];
    if (value == null || '$value'.isEmpty) return '—';
    return '$value';
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...crfs]
      ..sort((a, b) {
        int order(Object? v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
        return order(a['display_order']).compareTo(order(b['display_order']));
      });

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 22,
        headingRowHeight: 36,
        dataRowMinHeight: 34,
        dataRowMaxHeight: 40,
        columns: const [
          DataColumn(label: Text('Form')),
          DataColumn(label: Text('Primary key')),
          DataColumn(label: Text('Parent')),
          DataColumn(label: Text('Links on')),
          DataColumn(label: Text('Counter')),
          DataColumn(label: Text('Count field')),
          DataColumn(label: Text('Auto start')),
          DataColumn(label: Text('Enforce')),
        ],
        rows: [
          for (final crf in sorted)
            DataRow(
              cells: [
                DataCell(Text(_cell(crf, 'tablename'))),
                DataCell(Text(_cell(crf, 'primarykey'))),
                DataCell(Text(_cell(crf, 'parenttable'))),
                DataCell(Text(_cell(crf, 'linkingfield'))),
                DataCell(Text(_cell(crf, 'incrementfield'))),
                DataCell(Text(_cell(crf, 'repeat_count_field'))),
                DataCell(Text(_autoStart(crf))),
                DataCell(Text(_enforce(crf))),
              ],
            ),
        ],
      ),
    );
  }

  static String _autoStart(Map<String, dynamic> crf) {
    final raw = crf['auto_start_repeat'];
    final value = raw is int ? raw : int.tryParse('${raw ?? ''}') ?? 0;
    return switch (value) {
      1 => '1 · prompt',
      2 => '2 · force',
      _ => '0 · off',
    };
  }

  static String _enforce(Map<String, dynamic> crf) {
    final raw = crf['repeat_enforce_count'];
    if (raw == null || '$raw'.isEmpty) return '—';
    final value = raw is int ? raw : int.tryParse('$raw') ?? 1;
    return switch (value) {
      0 => '0 · any count',
      2 => '2 · must match',
      3 => '3 · auto-correct',
      _ => '1 · ask',
    };
  }
}
