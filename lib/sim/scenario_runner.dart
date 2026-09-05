import 'package:datakollecta/services/auto_fields.dart';
import 'package:datakollecta/services/db_service.dart';
import 'package:datakollecta/services/repeat_count_service.dart';
import 'package:datakollecta/services/repeat_loop_runner.dart';
import 'package:datakollecta/services/repeat_plan_service.dart';

import 'form_runner.dart';
import 'virtual_respondent.dart';

/// One parent interview and every child it led to.
class Scenario {
  Scenario({
    required this.parent,
    required this.children,
    required this.repeats,
    required this.livelocked,
  });

  final FormRun parent;
  final List<FormRun> children;

  /// One entry per repeating child form the parent triggered.
  final List<RepeatOutcome> repeats;

  /// True when a repeat loop hit its iteration bound. Never reachable by a
  /// person; always a defect in the package or the loop.
  final bool livelocked;

  int get recordCount => 1 + children.length;
}

/// What one repeating child form did, and what it left on the parent.
class RepeatOutcome {
  RepeatOutcome({
    required this.childTable,
    required this.countField,
    required this.declared,
    required this.entered,
    required this.enforceMode,
    required this.autoStartRepeat,
    required this.outcome,
    required this.countAfter,
    required this.acceptedUpdate,
  });

  final String childTable;
  final String countField;

  /// What the parent said there would be.
  final int declared;

  /// What was actually saved.
  final int entered;

  final int enforceMode;
  final int autoStartRepeat;

  /// What `RepeatCountService` decided, or null when it declined to decide.
  final RepeatCountOutcome? outcome;

  /// The parent's count column after reconciliation.
  final int? countAfter;

  /// For `askToUpdate`, which button the simulated interviewer pressed.
  /// Null when that question never arose.
  final bool? acceptedUpdate;
}

/// Runs a parent form and then whatever repeats follow it.
///
/// This is where the `auto_start_repeat` x `repeat_enforce_count` matrix
/// actually gets exercised. `RepeatPlanService` decides which children repeat
/// and how many times, `RepeatLoopRunner` runs the loop, and
/// `RepeatCountService` reconciles the parent's count afterwards -- all three
/// the field app's own, so what is being tested is the app rather than a
/// description of it.
///
/// The one thing supplied here is the interviewer: whether they complete each
/// child, and which button they press when asked to update a mismatched count.
class ScenarioRunner {
  ScenarioRunner({
    required this.surveyId,
    required this.respondent,
    this.childrenToComplete,
    this.acceptCountUpdate = true,
    this.onSkipEvaluated,
  });

  final String surveyId;
  final VirtualRespondent respondent;

  /// Passed to every `FormRunner` this scenario creates, so skip coverage
  /// spans the parent and its children rather than the parent alone.
  final void Function(String ruleId, bool fired)? onSkipEvaluated;

  /// How many children to actually complete, per child table. Absent means
  /// "as many as the parent asked for". This is what lets a caller produce the
  /// fewer/equal/more cases the matrix is about.
  final Map<String, int>? childrenToComplete;

  /// Which button to press for `askToUpdate` (enforce mode 1). The outcome
  /// alone cannot say whether the parent's count was rewritten, so the choice
  /// is recorded rather than inferred.
  final bool acceptCountUpdate;

  Future<Scenario> run(String parentTable) async {
    final parent = await FormRunner(
      surveyId: surveyId,
      tableName: parentTable,
      respondent: respondent,
      onSkipEvaluated: onSkipEvaluated,
    ).run();

    final children = <FormRun>[];
    final repeats = <RepeatOutcome>[];
    var livelocked = false;

    if (!parent.saved) {
      return Scenario(
        parent: parent,
        children: children,
        repeats: repeats,
        livelocked: livelocked,
      );
    }

    final crfs = await DbService.getExistingRecords(surveyId, 'crfs');
    final plans = RepeatPlanService.plan(
      crfs: crfs,
      parentTableName: parentTable,
      answers: parent.answers,
    );

    for (final plan in plans) {
      final enforceMode = RepeatCountService.parseEnforceMode(
        plan.crf['repeat_enforce_count'],
      );
      final target =
          childrenToComplete?[plan.childTableName] ?? plan.repeatCount;
      var savedThisPlan = 0;
      bool? accepted;

      final outcome = await const RepeatLoopRunner().run(
        requested: plan.repeatCount,
        enforceMode: enforceMode,
        openChild: (index, completed) async {
          // Declining is how the fewer-than-declared case is produced. In mode
          // 2 the loop refuses to accept it, which is exactly the behaviour
          // under test -- so the bound in RepeatLoopRunner is what stops this.
          if (completed >= target) return false;

          final run =
              await FormRunner(
                surveyId: surveyId,
                tableName: plan.childTableName,
                respondent: respondent,
                onSkipEvaluated: onSkipEvaluated,
              ).run(
                prepopulatedAnswers: {
                  plan.linkingField: plan.linkingValue,
                  if (parent.answers[AutoFields.parentUniqueIdField] != null ||
                      parent.uniqueId != null)
                    AutoFields.parentUniqueIdField: parent.uniqueId,
                },
                crf: plan.crf,
              );
          children.add(run);
          if (run.saved) savedThisPlan++;
          return run.saved;
        },
        insist: (index, completed) async {},
        warnBelowMinimum: (index, completed) async {},
        isBelowMinimum: () async {
          final reconciliation = await RepeatCountService.evaluate(
            surveyId: surveyId,
            childTableName: plan.childTableName,
            linkingValue: plan.linkingValue,
          );
          return reconciliation?.outcome == RepeatCountOutcome.belowMinimum;
        },
        reconcile: () async {
          final reconciliation = await RepeatCountService.evaluate(
            surveyId: surveyId,
            childTableName: plan.childTableName,
            linkingValue: plan.linkingValue,
          );
          if (reconciliation == null) return;

          // Mirrors what the screen does with each outcome: mode 3 writes
          // before showing anything, mode 1 writes only if the interviewer
          // agrees, and everything else leaves the count alone.
          if (reconciliation.outcome == RepeatCountOutcome.updateSilently) {
            await RepeatCountService.applyCount(
              surveyId: surveyId,
              reconciliation: reconciliation,
            );
          } else if (reconciliation.outcome == RepeatCountOutcome.askToUpdate) {
            accepted = acceptCountUpdate;
            if (acceptCountUpdate) {
              await RepeatCountService.applyCount(
                surveyId: surveyId,
                reconciliation: reconciliation,
              );
            }
          }
        },
      );

      if (outcome.livelocked) livelocked = true;

      final reconciliation = await RepeatCountService.evaluate(
        surveyId: surveyId,
        childTableName: plan.childTableName,
        linkingValue: plan.linkingValue,
      );

      final countAfter = await DbService.getFieldValue(
        surveyId: surveyId,
        tableName: parentTable,
        field: plan.crf['repeat_count_field'].toString(),
        where: '${plan.linkingField} = ?',
        whereArgs: [plan.linkingValue],
      );

      repeats.add(
        RepeatOutcome(
          childTable: plan.childTableName,
          countField: plan.crf['repeat_count_field'].toString(),
          declared: plan.repeatCount,
          entered: savedThisPlan,
          enforceMode: enforceMode,
          autoStartRepeat: plan.autoStartRepeat,
          // Re-read after the loop, so it describes the state that was left
          // behind rather than the one that prompted the write.
          outcome: reconciliation?.outcome,
          countAfter: int.tryParse('${countAfter ?? ''}'),
          acceptedUpdate: accepted,
        ),
      );
    }

    return Scenario(
      parent: parent,
      children: children,
      repeats: repeats,
      livelocked: livelocked,
    );
  }
}
