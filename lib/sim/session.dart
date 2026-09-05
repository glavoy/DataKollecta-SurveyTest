import 'package:datakollecta/services/db_service.dart';

import '../installer.dart';
import 'invariants.dart';
import 'report.dart';
import 'scenario_runner.dart';
import 'virtual_respondent.dart';

/// How a run is configured.
class RunSettings {
  const RunSettings({
    this.runs = 100,
    this.seed,
    this.strategies = const [
      RespondentStrategy.random,
      RespondentStrategy.boundaryValues,
      RespondentStrategy.skipMaximising,
      RespondentStrategy.skipAvoiding,
      RespondentStrategy.dontKnowHeavy,
    ],
    this.backtrackRate = 0.15,
  });

  final int runs;

  /// Null means "pick one and report it", so a run is always replayable even
  /// when the designer did not choose a seed.
  final int? seed;

  final List<RespondentStrategy> strategies;

  /// How often the interviewer goes back a question. Going back and forward
  /// again is the only way to reach some of what the engine does.
  final double backtrackRate;
}

/// Runs a batch of interviews against an installed package and reports.
class SimulationSession {
  const SimulationSession(this.package);

  final InstalledPackage package;

  /// The form to start from -- the base form, or the only form there is.
  String get startTable =>
      (package.baseCrf?['tablename'] ?? package.crfs.first['tablename'])
          .toString();

  Future<RunReport> run(
    RunSettings settings, {
    void Function(int done, int total)? onProgress,
  }) async {
    final base = settings.seed ?? ReportBuilder.randomSeed();
    final builder = ReportBuilder();
    final invariants = Invariants(package.surveyId);

    for (var i = 0; i < settings.runs; i++) {
      final seed = ReportBuilder.seedFor(base, i);
      final strategy = settings.strategies[i % settings.strategies.length];

      final scenario = await ScenarioRunner(
        surveyId: package.surveyId,
        respondent: VirtualRespondent(
          seed: seed,
          strategy: strategy,
          backtrackRate: settings.backtrackRate,
        ),
      ).run(startTable);

      builder.observe(scenario, seed: seed);
      for (final finding in await invariants.check(scenario, seed: seed)) {
        builder.add(finding);
      }

      onProgress?.call(i + 1, settings.runs);
    }

    return builder.build();
  }

  /// How many records the package holds now, per table. Shown after a run so
  /// the designer can go and look at them.
  Future<Map<String, int>> recordCounts() async {
    final counts = <String, int>{};
    for (final crf in package.crfs) {
      final table = crf['tablename']?.toString();
      if (table == null || table.isEmpty) continue;
      counts[table] = await DbService.getRecordCount(
        surveyId: package.surveyId,
        tableName: table,
      );
    }
    return counts;
  }
}
