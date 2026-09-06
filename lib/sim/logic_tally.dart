/// What the interviews did with one logic check.
///
/// A check that never fired is not evidence of anything -- random respondents
/// rarely satisfy a cross-field condition -- but a check that was evaluated
/// only ever with one of its operands blank cannot fire at all, and on a form
/// where that operand is skipped on every route to the check, it never will.
class LogicTally {
  int evaluated = 0;
  int fired = 0;

  /// Evaluations where some field the condition names, other than the
  /// question's own, was unanswered. The engine treats that as "passes".
  int nullOperand = 0;

  /// Which fields were blank, and how often.
  final Map<String, int> nullFields = {};

  void merge(LogicTally other) {
    evaluated += other.evaluated;
    fired += other.fired;
    nullOperand += other.nullOperand;
    for (final e in other.nullFields.entries) {
      nullFields.update(e.key, (v) => v + e.value, ifAbsent: () => e.value);
    }
  }

  static String idFor(String table, String owner, int index, String condition) =>
      '$table.$owner.logic[$index] ${condition.replaceAll(RegExp(r'\s+'), ' ').trim()}';

  /// The identifiers a condition names, minus its keywords and anything in
  /// quotes. The same scan `FormRunner._blockedByAnotherField` uses.
  static Set<String> identifiersIn(String condition) {
    final unquoted = condition.replaceAll(RegExp(r"'[^']*'"), ' ');
    const keywords = {'and', 'or', 'not', 'contains', 'does', 'contain'};
    return {
      for (final m in RegExp(r'[A-Za-z_]\w*').allMatches(unquoted))
        if (!keywords.contains(m.group(0)!.toLowerCase())) m.group(0)!,
    };
  }
}
