import 'package:datakollecta/models/question.dart';
import 'package:datakollecta/services/survey_loader.dart';
import 'package:datakollecta/services/survey_navigation_service.dart';

/// One skip rule with an identity, a position, and the range it clears.
///
/// `SkipCondition` carries none of those: it does not override `==`, the same
/// (field, operator, value, target) can legitimately appear twice in one form,
/// and `FormRunner` and `SimulationSession` each load the questions separately
/// -- so nothing outside one `FormRunner` may hold a `SkipCondition` and expect
/// it to mean anything. This value object is what crosses those boundaries.
class RuleRef {
  const RuleRef({
    required this.id,
    required this.owner,
    required this.isPreskip,
    required this.order,
    required this.field,
    required this.condition,
    required this.response,
    required this.responseType,
    required this.target,
    required this.ownerIndex,
    required this.targetIndex,
  });

  /// `FormRunner.skipRuleId` format, e.g.
  /// `hh_info.exclreason.preskip[0] enrolled = 1 -> swater`.
  final String id;

  /// The question the rule is written on.
  final String owner;
  final bool isPreskip;
  final int order;

  /// What the rule tests and where it goes.
  final String field;
  final String condition;
  final String response;
  final String responseType;
  final String target;

  final int ownerIndex;

  /// Index of the target question; `questions.length` for the reserved
  /// target `end`; `-1` for a target that does not exist or lies behind the
  /// owner. The engine ignores both of the latter, so they clear nothing.
  final int targetIndex;

  String get kind => isPreskip ? 'preskip' : 'postskip';

  bool get isDynamic => responseType == 'dynamic';

  bool get skipsToEnd => targetIndex >= 0 && target.trim().toLowerCase() ==
      SurveyNavigationService.endOfFormSkipTarget;

  /// Whether the engine would honour this rule at all.
  bool get jumpsForward => targetIndex > ownerIndex;

  /// The first index this rule clears when it fires. A preskip jumps from its
  /// own question; a postskip from the one after.
  int get clearedFrom => isPreskip ? ownerIndex : ownerIndex + 1;

  /// Whether firing this rule denies the question at [index] a display.
  bool jumpsOver(int index) =>
      jumpsForward && index >= clearedFrom && index < targetIndex;

  /// The id without its table prefix, for a `Finding.field`.
  String nameIn(String table) =>
      id.startsWith('$table.') ? id.substring(table.length + 1) : id;

  static String idFor(
    String table,
    String owner,
    String kind,
    int order,
    SkipCondition rule,
  ) =>
      '$table.$owner.$kind[$order] '
      '${rule.fieldName} ${rule.condition} ${rule.response} '
      '-> ${rule.skipToFieldName}';

  @override
  String toString() => id;
}

/// The skip structure of one form, computed once from its questions.
///
/// Everything here is a pure function of the XML: which rules exist, what
/// each tests, and which questions each can close the route to. The report
/// builder, the steering planner, the decision table and the lint all read
/// this instead of each re-walking the question list with its own off-by-one.
class SkipTopology {
  SkipTopology._({
    required this.table,
    required this.order,
    required this.indexOf,
    required this.displayable,
    required this.informationQuestions,
    required this.rules,
    required this.rulesByTestedField,
    required this.rulesJumpingOver,
    required this.rulesOwnedBy,
  });

  final String table;

  /// Every fieldname in XML order, automatic and end screen included.
  final List<String> order;
  final Map<String, int> indexOf;

  /// Questions an interviewer can be shown: not `automatic`, not the
  /// end-of-survey screen.
  final Set<String> displayable;

  /// The `information` screens among [displayable].
  final Set<String> informationQuestions;

  final List<RuleRef> rules;
  final Map<String, List<RuleRef>> rulesByTestedField;

  /// Question -> rules whose cleared range covers it. Only forward rules
  /// appear; the engine ignores the rest.
  final Map<String, List<RuleRef>> rulesJumpingOver;
  final Map<String, List<RuleRef>> rulesOwnedBy;

  /// Every field some rule tests.
  Set<String> get gatingFields => rulesByTestedField.keys.toSet();

  /// The fields whose values decide whether [question] is shown.
  Set<String> gatingFieldsOf(String question) => {
        for (final r in rulesJumpingOver[question] ?? const <RuleRef>[]) r.field,
      };

  RuleRef? rule(String id) {
    for (final r in rules) {
      if (r.id == id) return r;
    }
    return null;
  }

  static SkipTopology of(String table, List<Question> questions) {
    final order = [for (final q in questions) q.fieldName];
    final indexOf = <String, int>{};
    for (var i = 0; i < order.length; i++) {
      indexOf.putIfAbsent(order[i], () => i);
    }
    final displayable = {
      for (final q in questions)
        if (q.type != QuestionType.automatic &&
            q.fieldName != SurveyLoader.endOfQuestionsField)
          q.fieldName,
    };
    final information = {
      for (final q in questions)
        if (q.type == QuestionType.information && displayable.contains(q.fieldName))
          q.fieldName,
    };

    int targetIndexOf(int ownerIndex, String target) {
      if (target.trim().toLowerCase() ==
          SurveyNavigationService.endOfFormSkipTarget) {
        return questions.length;
      }
      // Exact match, as `SurveyNavigationService._findQuestionByFieldName`.
      final index = order.indexOf(target);
      if (index < 0 || index <= ownerIndex) return -1;
      return index;
    }

    final rules = <RuleRef>[];
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      for (final kind in const ['preskip', 'postskip']) {
        final isPre = kind == 'preskip';
        final list = isPre ? q.preSkips : q.postSkips;
        for (var k = 0; k < list.length; k++) {
          final s = list[k];
          rules.add(
            RuleRef(
              id: RuleRef.idFor(table, q.fieldName, kind, k, s),
              owner: q.fieldName,
              isPreskip: isPre,
              order: k,
              field: s.fieldName,
              condition: s.condition,
              response: s.response,
              responseType: s.responseType,
              target: s.skipToFieldName,
              ownerIndex: i,
              targetIndex: targetIndexOf(i, s.skipToFieldName),
            ),
          );
        }
      }
    }

    final byField = <String, List<RuleRef>>{};
    final owned = <String, List<RuleRef>>{};
    final jumping = <String, List<RuleRef>>{};
    for (final r in rules) {
      (byField[r.field] ??= []).add(r);
      (owned[r.owner] ??= []).add(r);
      if (!r.jumpsForward) continue;
      final last = r.targetIndex < order.length ? r.targetIndex : order.length;
      for (var k = r.clearedFrom; k < last; k++) {
        (jumping[order[k]] ??= []).add(r);
      }
    }

    return SkipTopology._(
      table: table,
      order: List.unmodifiable(order),
      indexOf: Map.unmodifiable(indexOf),
      displayable: Set.unmodifiable(displayable),
      informationQuestions: Set.unmodifiable(information),
      rules: List.unmodifiable(rules),
      rulesByTestedField: Map.unmodifiable(byField),
      rulesJumpingOver: Map.unmodifiable(jumping),
      rulesOwnedBy: Map.unmodifiable(owned),
    );
  }
}
