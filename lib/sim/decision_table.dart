import 'package:datakollecta/services/field_comparator.dart';

import 'form_runner.dart';
import 'skip_topology.dart';

/// Where an answer led: next displayed question -> how many interview-hops.
class NextAfter {
  final Map<String, Map<String, int>> counts = {};

  void record(String value, String next) {
    (counts[value] ??= {}).update(next, (v) => v + 1, ifAbsent: () => 1);
  }

  /// Answer values seen, sorted numerically where they parse and textually
  /// otherwise, with blank last.
  List<String> get values => counts.keys.toList()..sort(compareValues);
}

/// How often a question was shown or skipped while one gating field held one
/// value, and -- when skipped -- which rules the engine said did it.
class GatingRow {
  int shown = 0;
  int skipped = 0;
  final Map<String, int> skippedByRule = {};
}

/// What the interviews showed about one form's skips, in the shape a
/// designer compares against the paper questionnaire.
class SkipDecisionTable {
  SkipDecisionTable({
    required this.table,
    required this.nextAfter,
    required this.gatingWhen,
    required this.fallThrough,
    required this.postskipOwners,
    required this.informationScreens,
    required this.fallThroughValues,
  });

  final String table;

  /// Gating field -> answer -> next displayed question -> count. "After
  /// `vx_card_no = 96`, the next question shown was `vx_card_no_oth` (30×)".
  final Map<String, NextAfter> nextAfter;

  /// Gated question -> `'field=value'` -> shown/skipped counts. The inverse
  /// reading: "`prevdiag_when` was shown 9 times while `prevdiag = -7`".
  final Map<String, Map<String, GatingRow>> gatingWhen;

  /// Question with postskips -> times none of them fired.
  final Map<String, int> fallThrough;

  /// Every question that carries postskips, so a zero can be shown too.
  final Set<String> postskipOwners;

  /// The `information` questions among [postskipOwners]. A terminal screen
  /// that falls through carries the interview on past its own ending.
  final Set<String> informationScreens;

  /// Question -> the gating values on the hops that fell through it, for the
  /// finding text.
  final Map<String, Map<String, int>> fallThroughValues;
}

/// Sorts answer values the way a code list reads: numbers by value, then
/// text, blank last.
int compareValues(String a, String b) {
  const blank = '(blank)';
  if (a == blank) return b == blank ? 0 : 1;
  if (b == blank) return -1;
  final na = num.tryParse(a);
  final nb = num.tryParse(b);
  if (na != null && nb != null) return na.compareTo(nb);
  if (na != null) return -1;
  if (nb != null) return 1;
  return a.compareTo(b);
}

/// Folds each interview's hops into a [SkipDecisionTable].
///
/// Nothing here evaluates a skip. Table A is the pair (answer, next displayed)
/// the engine produced; Table B attributes a display or a non-display to the
/// gating values present at that moment, and the *skipped by* column comes
/// from the rules the engine reported firing on that hop. The value columns
/// are correlation; the rule column is cause. The report says so.
class DecisionTableBuilder {
  DecisionTableBuilder(this.topology);

  final SkipTopology topology;

  static const int maxDistinctValues = 30;
  static const String blank = '(blank)';
  static const String other = '(other)';

  final Map<String, NextAfter> _nextAfter = {};
  final Map<String, Map<String, GatingRow>> _gatingWhen = {};
  final Map<String, int> _fallThrough = {};
  final Map<String, Map<String, int>> _fallThroughValues = {};

  /// Date literals some rule compares a field against, so a date answer can
  /// be bucketed as before / on / after the literal rather than as itself.
  late final Map<String, List<DateTime>> _dateLiterals = {
    for (final r in topology.rules)
      if (!r.isDynamic && DateTime.tryParse(r.response) != null)
        r.field: [
          ...?_dateLiterals[r.field],
          DateTime.parse(r.response),
        ],
  };

  void observe(FormRun run) {
    if (run.tableName != topology.table) return;
    for (final hop in run.hops) {
      _observeHop(hop);
    }
    for (final entry in run.postskipFallThroughs.entries) {
      _fallThrough.update(entry.key, (v) => v + entry.value,
          ifAbsent: () => entry.value);
    }
  }

  void _observeHop(Hop hop) {
    final fromIndex =
        hop.from == Hop.start ? -1 : (topology.indexOf[hop.from] ?? -1);
    final toIndex = hop.to == Hop.end
        ? topology.order.length
        : (topology.indexOf[hop.to] ?? topology.order.length);

    // Table A: where this answer led.
    if (hop.from != Hop.start && topology.gatingFields.contains(hop.from)) {
      (_nextAfter[hop.from] ??= NextAfter())
          .record(_norm(hop.from, hop.fromValue), hop.to);
    }

    // Table B, shown side.
    if (hop.to != Hop.end) {
      for (final g in topology.gatingFieldsOf(hop.to)) {
        _row(hop.to, g, hop.gating[g]).shown++;
      }
    }

    // Table B, skipped side: every displayable question strictly between.
    final fired = hop.firedRuleIds
        .map(topology.rule)
        .whereType<RuleRef>()
        .toList();
    for (var k = fromIndex + 1; k < toIndex && k < topology.order.length; k++) {
      final q = topology.order[k];
      if (!topology.displayable.contains(q)) continue;
      final culprits = [for (final r in fired) if (r.jumpsOver(k)) r.id];
      for (final g in topology.gatingFieldsOf(q)) {
        final row = _row(q, g, hop.gating[g]);
        row.skipped++;
        for (final id in culprits) {
          row.skippedByRule.update(id, (v) => v + 1, ifAbsent: () => 1);
        }
      }
    }

    // Table C detail: what the tested fields held when a screen fell through.
    if (hop.fellThrough) {
      final values = _fallThroughValues[hop.from] ??= {};
      for (final r in topology.rulesOwnedBy[hop.from] ?? const <RuleRef>[]) {
        if (r.isPreskip) continue;
        final label = '${r.field}=${_norm(r.field, hop.gating[r.field])}';
        values.update(label, (v) => v + 1, ifAbsent: () => 1);
      }
    }
  }

  GatingRow _row(String question, String field, Object? value) {
    final rows = _gatingWhen[question] ??= {};
    return rows.putIfAbsent('$field=${_norm(field, value)}', GatingRow.new);
  }

  /// The label a value gets in the tables. Dates collapse to their position
  /// relative to any literal a rule compares them with, since every interview
  /// would otherwise contribute a value of its own.
  String _norm(String field, Object? value) {
    if (value == null) return blank;
    if (value is DateTime) {
      final literals = _dateLiterals[field];
      if (literals == null || literals.isEmpty) return '(date)';
      final lit = literals.first;
      final iso = lit.toIso8601String().substring(0, 10);
      if (value.isBefore(lit)) return '<$iso';
      if (value.isAfter(lit)) return '>$iso';
      return '=$iso';
    }
    final text = FieldComparator.resolveText(value) ?? blank;
    if (text.isEmpty) return blank;
    final seen = _nextAfter[field]?.counts.keys ?? const <String>[];
    if (seen.length >= maxDistinctValues && !seen.contains(text)) return other;
    return text;
  }

  SkipDecisionTable build() {
    final owners = {
      for (final r in topology.rules) if (!r.isPreskip) r.owner,
    };
    return SkipDecisionTable(
      table: topology.table,
      nextAfter: Map.unmodifiable(_nextAfter),
      gatingWhen: Map.unmodifiable(_gatingWhen),
      fallThrough: Map.unmodifiable(_fallThrough),
      postskipOwners: owners,
      informationScreens: {
        for (final q in owners)
          if (topology.informationQuestions.contains(q)) q,
      },
      fallThroughValues: Map.unmodifiable(_fallThroughValues),
    );
  }
}
