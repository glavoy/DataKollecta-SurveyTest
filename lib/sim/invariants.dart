import 'package:datakollecta/services/answer_equality.dart';
import 'package:datakollecta/services/db_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'report.dart';
import 'scenario_runner.dart';

/// Checks a saved record against what the interview actually did.
///
/// Every check returns findings rather than throwing, so one run reports
/// everything wrong with it instead of the first thing.
class Invariants {
  const Invariants(this.surveyId);

  final String surveyId;

  /// The generator writes these into every form; they are not answers.
  static const Set<String> systemFields = {
    'starttime',
    'startdate',
    'uniqueid',
    'swver',
    'survey_id',
    'lastmod',
    'stoptime',
    'parent_uniqueid',
    'synced_at',
  };

  Future<List<Finding>> check(Scenario scenario, {required int seed}) async {
    final findings = <Finding>[];
    final db = await DbService.getDatabaseForQueries(surveyId);

    for (final run in [scenario.parent, ...scenario.children]) {
      if (!run.saved) continue;
      final rows = await db.query(
        run.tableName,
        where: 'uniqueid = ?',
        whereArgs: [run.uniqueId],
      );
      if (rows.isEmpty) {
        findings.add(
          Finding(
            code: 'record_missing',
            table: run.tableName,
            seed: seed,
            detail:
                'saveInterview reported success but no row with uniqueid '
                '${run.uniqueId} is in the table.',
          ),
        );
        continue;
      }
      findings.addAll(_checkRow(run, rows.single, seed));
    }

    findings.addAll(await _checkKeys(scenario, db, seed));
    return findings;
  }

  List<Finding> _checkRow(dynamic run, Map<String, Object?> stored, int seed) {
    final findings = <Finding>[];

    // Every answer that was given is in the row, unchanged.
    //
    // Compared through AnswerEquality rather than by string, because that is
    // the rule the app itself uses for "are these the same answer" -- "04"
    // equals "4", and two spellings of one instant are equal. A stricter
    // comparison here would report the app's own normalisation as data loss.
    for (final entry in (run.storedRow as Map<String, dynamic>).entries) {
      if (entry.value == null) continue;
      if (systemFields.contains(entry.key)) continue;
      if (!stored.containsKey(entry.key)) continue;

      if (!AnswerEquality.sameAnswer(stored[entry.key], entry.value)) {
        findings.add(
          Finding(
            code: 'answer_changed',
            table: run.tableName as String,
            field: entry.key,
            seed: seed,
            detail:
                'answered "${entry.value}" but the row holds '
                '"${stored[entry.key]}".',
          ),
        );
      }
    }

    // A question that was never displayed must not have left a value behind.
    // This is the check that catches a skip failing to clear what it jumped
    // over, which is how a record ends up describing an interview that did
    // not happen.
    final visited = run.visitedFields as Set<String>;
    for (final column in stored.keys) {
      if (systemFields.contains(column)) continue;
      final value = stored[column];
      if (value == null || '$value'.isEmpty) continue;
      if (visited.contains(column)) continue;
      // Primary keys and linking values are computed, not displayed.
      if ((run.storedRow as Map<String, dynamic>).containsKey(column) &&
          !(run.route as List<String>).contains(column)) {
        continue;
      }
      findings.add(
        Finding(
          code: 'value_never_asked',
          table: run.tableName as String,
          field: column,
          seed: seed,
          detail: 'holds "$value" but the question was never displayed.',
        ),
      );
    }

    // The reserved variables, which every record must carry and which have to
    // be in order -- an automatic field records the moment navigation reached
    // it, so a wrong order means one moved.
    final start = DateTime.tryParse('${stored['starttime'] ?? ''}');
    final stop = DateTime.tryParse('${stored['stoptime'] ?? ''}');
    if (start == null) {
      findings.add(
        Finding(
          code: 'missing_starttime',
          table: run.tableName as String,
          seed: seed,
          detail: 'no parseable starttime.',
        ),
      );
    }
    if (stop != null && start != null && stop.isBefore(start)) {
      findings.add(
        Finding(
          code: 'stoptime_before_starttime',
          table: run.tableName as String,
          seed: seed,
          detail:
              'stoptime $stop precedes starttime $start, so an automatic '
              'field is computed in the wrong place in the form.',
        ),
      );
    }

    return findings;
  }

  Future<List<Finding>> _checkKeys(
    Scenario scenario,
    Database db,
    int seed,
  ) async {
    final findings = <Finding>[];
    final tables = {
      scenario.parent.tableName,
      ...scenario.children.map((c) => c.tableName),
    };

    for (final table in tables) {
      final crf = await DbService.getCrfConfig(surveyId, table);
      final primaryKey = crf?['primarykey']?.toString();
      if (primaryKey == null || primaryKey.isEmpty) continue;

      final columns = primaryKey
          .split(',')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .toList();
      if (columns.isEmpty) continue;

      // The composite key must be unique. The database does not enforce this
      // for a sibling ordinal -- deliberately, because a failed insert would
      // lose an interview -- so this query is the only thing that would find a
      // counter bug.
      final quoted = columns.map((c) => '"$c"').join(', ');
      final duplicates = await db.rawQuery(
        'SELECT $quoted, COUNT(*) AS n FROM "$table" '
        'GROUP BY $quoted HAVING n > 1',
      );
      for (final row in duplicates) {
        final key = columns.map((c) => '${row[c]}').join(', ');
        findings.add(
          Finding(
            code: 'duplicate_primary_key',
            table: table,
            field: primaryKey,
            seed: seed,
            detail: '$key appears ${row['n']} times.',
          ),
        );
      }

      // A key of '-9' means generation failed and the record is unidentifiable.
      for (final column in columns) {
        final degraded = await db.rawQuery(
          'SELECT COUNT(*) AS n FROM "$table" WHERE "$column" = ?',
          ['-9'],
        );
        final n = degraded.single['n'] as int;
        if (n > 0) {
          findings.add(
            Finding(
              code: 'degraded_key',
              table: table,
              field: column,
              seed: seed,
              detail:
                  '$n record(s) hold the failure value -9, so the idconfig '
                  'could not build a key from the answers given.',
            ),
          );
        }
      }
    }

    return findings;
  }
}
