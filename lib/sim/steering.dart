import 'package:datakollecta/models/question.dart';
import 'package:datakollecta/services/field_comparator.dart';

import 'skip_topology.dart';

/// One thing a steered interview must make true about one field.
///
/// A value object rather than a `SkipCondition`, because plans are built from
/// one load of the questions and answered against another, and because the
/// same rule read as "make it fire" and "make it not fire" are two different
/// constraints.
class SteerConstraint {
  const SteerConstraint({
    required this.ruleId,
    required this.field,
    required this.condition,
    required this.response,
    required this.responseType,
    required this.wantFire,
  });

  factory SteerConstraint.of(RuleRef rule, {required bool wantFire}) =>
      SteerConstraint(
        ruleId: rule.id,
        field: rule.field,
        condition: rule.condition,
        response: rule.response,
        responseType: rule.responseType,
        wantFire: wantFire,
      );

  final String ruleId;
  final String field;
  final String condition;
  final String response;
  final String responseType;
  final bool wantFire;

  bool get isDynamic => responseType == 'dynamic';

  /// Whether storing [value] for [field] gives the rule the wanted outcome.
  ///
  /// Evaluated through the app's own comparator, with the app's own fail-open
  /// rule: an unanswered field never fires, so a blank satisfies exactly the
  /// constraints that want the rule *not* to fire.
  bool satisfiedBy(Object? value, AnswerMap answers) {
    final text = FieldComparator.resolveText(value);
    if (text == null) return !wantFire;
    final rhs = isDynamic
        ? FieldComparator.resolveTextOrEmpty(answers[response])
        : response;
    return FieldComparator.compare(text, condition, rhs) == wantFire;
  }

  /// Same rule, opposite wish.
  bool contradicts(SteerConstraint other) =>
      field == other.field &&
      condition == other.condition &&
      response == other.response &&
      responseType == other.responseType &&
      wantFire != other.wantFire;

  String get key => '$field|$condition|$response|$responseType|$wantFire';

  @override
  String toString() =>
      '$field ${wantFire ? '' : 'not '}($condition $response)';
}

enum SteerPurpose { fire, notFire, reach }

/// What one steered interview is trying to prove.
class SteeringPlan {
  const SteeringPlan({
    required this.table,
    required this.purpose,
    required this.subject,
    required this.constraintsByField,
    required this.contradictions,
    this.computedFields = const {},
  });

  /// Fields the plan needs a value from but no interviewer ever types: an
  /// `automatic` or calculated question, or a field from another form. The
  /// respondent cannot steer these; whatever the engine computes is what the
  /// rule sees.
  final Set<String> computedFields;

  final String table;
  final SteerPurpose purpose;

  /// A rule id for [SteerPurpose.fire]/[SteerPurpose.notFire]; a question
  /// for [SteerPurpose.reach].
  final String subject;

  final Map<String, List<SteerConstraint>> constraintsByField;

  /// Pairs of constraints that ask one field for opposite outcomes of the
  /// same test. A plan with any of these cannot be satisfied by any answer,
  /// which is itself the finding: the rules involved close the route between
  /// them.
  final List<(SteerConstraint, SteerConstraint)> contradictions;

  bool get feasible => contradictions.isEmpty;

  String get purposeLabel => switch (purpose) {
        SteerPurpose.fire => 'make it fire',
        SteerPurpose.notFire => 'keep it from firing',
        SteerPurpose.reach => 'reach the question',
      };

  /// A stable key so identical plans built for different subjects run once.
  String get signature {
    final keys = constraintsByField.values
        .expand((c) => c)
        .map((c) => c.key)
        .toList()
      ..sort();
    return '$table|${keys.join(';')}';
  }

  String describeValues(Map<String, Object?> chosen) => [
        for (final f in constraintsByField.keys)
          if (computedFields.contains(f))
            '$f (computed, not steerable)'
          else
            '$f=${FieldComparator.resolveText(chosen[f]) ?? '(blank)'}',
      ].join(', ');
}

/// Builds the constraint sets that make a rule fire, keep it from firing, or
/// bring an interview to a question.
///
/// Nothing here evaluates anything. It walks the topology: to have a question
/// displayed, every rule that can jump over it must not fire, and every field
/// those rules test must itself be displayed (an unanswered field never fires,
/// so a rule on a skipped field proves nothing). To have a rule tried at all,
/// the rules before it in the same cell must not fire, because the engine
/// stops at the first match.
class SteeringPlanner {
  const SteeringPlanner._();

  static List<SteeringPlan> forRules(SkipTopology t) {
    final plans = <SteeringPlan>[];
    for (final rule in t.rules) {
      if (!rule.jumpsForward) continue;
      for (final want in const [true, false]) {
        final constraints = <String, List<SteerConstraint>>{};
        _add(constraints, SteerConstraint.of(rule, wantFire: want));
        _precede(t, rule, constraints);
        // A preskip's own cell is handled by _precede (earlier siblings must
        // not fire; later ones are never reached). A postskip is evaluated
        // only once its question was displayed, so every preskip on that
        // question must be held off too.
        _keepOpen(t, rule.owner, constraints, {}, excludeOwnRules: rule.isPreskip);
        _reachField(t, rule.field, constraints, {});
        plans.add(
          SteeringPlan(
            table: t.table,
            purpose: want ? SteerPurpose.fire : SteerPurpose.notFire,
            subject: rule.id,
            constraintsByField: constraints,
            contradictions: _contradictions(constraints),
            computedFields: _computed(t, constraints),
          ),
        );
      }
    }
    return plans;
  }

  static SteeringPlan toReach(SkipTopology t, String question) {
    final constraints = <String, List<SteerConstraint>>{};
    _keepOpen(t, question, constraints, {}, excludeOwnRules: false);
    return SteeringPlan(
      table: t.table,
      purpose: SteerPurpose.reach,
      subject: question,
      constraintsByField: constraints,
      contradictions: _contradictions(constraints),
      computedFields: _computed(t, constraints),
    );
  }

  static Set<String> _computed(
    SkipTopology t,
    Map<String, List<SteerConstraint>> constraints,
  ) =>
      {for (final f in constraints.keys) if (!t.displayable.contains(f)) f};

  static void _add(
    Map<String, List<SteerConstraint>> into,
    SteerConstraint c,
  ) {
    final list = into[c.field] ??= [];
    if (list.any((e) => e.key == c.key)) return;
    list.add(c);
  }

  /// Earlier siblings in the same cell must not fire, or this rule is never
  /// evaluated.
  static void _precede(
    SkipTopology t,
    RuleRef rule,
    Map<String, List<SteerConstraint>> into,
  ) {
    for (final sibling in t.rulesOwnedBy[rule.owner] ?? const <RuleRef>[]) {
      if (sibling.isPreskip != rule.isPreskip) continue;
      if (sibling.order >= rule.order) continue;
      _add(into, SteerConstraint.of(sibling, wantFire: false));
      _reachField(t, sibling.field, into, {});
    }
  }

  /// Every rule that can jump over [question] must not fire.
  static void _keepOpen(
    SkipTopology t,
    String question,
    Map<String, List<SteerConstraint>> into,
    Set<String> visiting, {
    required bool excludeOwnRules,
  }) {
    if (!visiting.add(question)) return;
    for (final j in t.rulesJumpingOver[question] ?? const <RuleRef>[]) {
      if (excludeOwnRules && j.owner == question) continue;
      _add(into, SteerConstraint.of(j, wantFire: false));
      _reachField(t, j.field, into, visiting);
    }
  }

  /// A tested field must be displayed to hold a value at all.
  static void _reachField(
    SkipTopology t,
    String field,
    Map<String, List<SteerConstraint>> into,
    Set<String> visiting,
  ) {
    if (!t.displayable.contains(field)) return;
    _keepOpen(t, field, into, visiting, excludeOwnRules: false);
  }

  static List<(SteerConstraint, SteerConstraint)> _contradictions(
    Map<String, List<SteerConstraint>> constraints,
  ) {
    final found = <(SteerConstraint, SteerConstraint)>[];
    for (final list in constraints.values) {
      for (var i = 0; i < list.length; i++) {
        for (var k = i + 1; k < list.length; k++) {
          if (list[i].contradicts(list[k])) found.add((list[i], list[k]));
        }
      }
    }
    return found;
  }
}

/// What one steered interview turned out to prove.
class SteeringOutcome {
  const SteeringOutcome({
    required this.plan,
    required this.seed,
    required this.achieved,
    required this.reason,
    required this.valuesChosen,
  });

  final SteeringPlan plan;
  final int? seed;
  final bool achieved;

  /// Why not, when [achieved] is false.
  final String reason;

  /// Field -> the value the steered respondent actually stored.
  final Map<String, Object?> valuesChosen;

  String get subject => plan.subject;
  SteerPurpose get purpose => plan.purpose;
}
