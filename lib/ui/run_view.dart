import 'package:flutter/material.dart';

import '../sim/session.dart';

/// How many interviews to run, and with what.
class RunView extends StatefulWidget {
  const RunView({
    super.key,
    required this.busy,
    required this.done,
    required this.total,
    required this.onRun,
  });

  final bool busy;
  final int done;
  final int total;
  final ValueChanged<RunSettings> onRun;

  @override
  State<RunView> createState() => _RunViewState();
}

class _RunViewState extends State<RunView> {
  int _runs = 100;
  final TextEditingController _seed = TextEditingController();

  @override
  void dispose() {
    _seed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Run interviews', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Each run is a whole household: the base form, then every child '
              'form its answers call for. The database is emptied first, so '
              'counters start where a new device would.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Interviews: $_runs',
                        style: theme.textTheme.labelLarge,
                      ),
                      Slider(
                        value: _runs.toDouble(),
                        min: 10,
                        max: 2000,
                        divisions: 199,
                        label: '$_runs',
                        onChanged: widget.busy
                            ? null
                            : (v) => setState(() => _runs = v.round()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _seed,
                    enabled: !widget.busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Seed (optional)',
                      helperText: 'Repeats an earlier run exactly',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: widget.busy
                      ? null
                      : () => widget.onRun(
                          RunSettings(
                            runs: _runs,
                            seed: int.tryParse(_seed.text.trim()),
                          ),
                        ),
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Run $_runs interviews'),
                ),
                const SizedBox(width: 16),
                if (widget.busy && widget.total > 0)
                  Text(
                    '${widget.done} of ${widget.total}',
                    style: theme.textTheme.bodyMedium,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
