import 'package:flutter/material.dart';

import '../installer.dart';
import '../sim/report.dart';

/// What the run found.
class ReportView extends StatelessWidget {
  const ReportView({super.key, required this.report, required this.package});

  final RunReport report;
  final InstalledPackage package;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  report.clean ? Icons.check_circle : Icons.error,
                  color: report.clean ? Colors.green.shade700 : scheme.error,
                ),
                const SizedBox(width: 10),
                Text(
                  report.clean
                      ? 'No problems found'
                      : '${report.findings.length} problem(s) found',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${report.runs} interviews, ${report.records} records, '
              'in ${report.elapsed.inSeconds}s',
              style: theme.textTheme.bodySmall,
            ),

            if (report.findings.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final finding in report.findings.take(50))
                _FindingTile(finding: finding),
              if (report.findings.length > 50)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '… and ${report.findings.length - 50} more',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],

            const SizedBox(height: 20),
            Text('Coverage', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'A clean run only means something for the questions it actually '
              'reached. Anything listed here was not tested.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 24,
              runSpacing: 10,
              children: [
                _Stat('Questions reached', '${report.questionsSeen.length}'),
                _Stat(
                  'Reached but never answered',
                  '${report.neverAnswered.length}',
                ),
                _Stat(
                  'Repeat settings exercised',
                  report.repeatCells.isEmpty
                      ? 'none'
                      : report.repeatCells.join(', '),
                ),
              ],
            ),

            if (report.unanswerable.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Section(
                title: 'Questions with nothing to choose',
                subtitle:
                    'A csv or database filter matched no rows, so the '
                    'interviewer would see an empty list.',
                entries: report.unanswerable.entries
                    .map((e) => '${e.key} — ${e.value} time(s)')
                    .toList(),
              ),
            ],

            if (report.blocked.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Section(
                title: 'Logic checks that fired',
                subtitle:
                    'These stop the interviewer moving on. Expected for '
                    'deliberately invalid answers; worth reading if a message '
                    'appears far more often than the rest.',
                entries: report.blocked.entries
                    .map((e) => '${e.value}× ${e.key}')
                    .take(12)
                    .toList(),
              ),
            ],

            if (report.neverAnswered.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Section(
                title: 'Reached but never answered',
                subtitle:
                    'Displayed and always left blank. Normal for '
                    'optional questions and information screens.',
                entries: report.neverAnswered.take(20).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile({required this.finding});

  final Finding finding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4, right: 10),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: theme.colorScheme.error,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${finding.where} — ${finding.code}',
                  style: theme.textTheme.labelLarge,
                ),
                SelectableText(
                  finding.detail,
                  style: theme.textTheme.bodySmall,
                ),
                if (finding.seed != null)
                  Text(
                    'Replay with seed ${finding.seed}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        Text(value, style: theme.textTheme.titleSmall),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.entries,
  });

  final String title;
  final String subtitle;
  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        Text(subtitle, style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: SelectableText('• $entry', style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}
