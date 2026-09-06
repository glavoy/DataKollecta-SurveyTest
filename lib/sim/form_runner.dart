import 'dart:io';

import 'package:datakollecta/config/app_config.dart';
import 'package:datakollecta/models/question.dart';
import 'package:datakollecta/services/answer_storage_service.dart';
import 'package:datakollecta/services/answer_validation_service.dart';
import 'package:datakollecta/services/app_strings.dart';
import 'package:datakollecta/services/auto_fields.dart';
import 'package:datakollecta/services/automatic_field_service.dart';
import 'package:datakollecta/services/child_increment_service.dart';
import 'package:datakollecta/services/csv_data_service.dart';
import 'package:datakollecta/services/database_response_service.dart';
import 'package:datakollecta/services/db_service.dart';
import 'package:datakollecta/services/logic_service.dart';
import 'package:datakollecta/services/survey_config_service.dart';
import 'package:datakollecta/services/survey_loader.dart';
import 'package:datakollecta/services/survey_navigation_service.dart';
import 'package:path/path.dart' as p;

import 'logic_tally.dart';
import 'skip_topology.dart';
import 'virtual_respondent.dart';

/// One forward move of the interview: from a displayed question (or the
/// start of the form) to the next question displayed.
///
/// Everything the decision table knows comes from these. [fromValue] is the
/// answer at the moment of advancing; [firedRuleIds] is every rule the engine
/// reported firing on the way, so what closed the route to each question in
/// between is a fact the engine stated, not one inferred here; [gating] is a
/// snapshot of every field some skip rule tests, taken at the same moment.
class Hop {
  const Hop({
    required this.from,
    required this.to,
    required this.fromValue,
    required this.firedRuleIds,
    required this.evaluatedRuleIds,
    required this.gating,
    required this.fellThrough,
  });

  /// The start of the form, before any question is displayed.
  static const String start = '<start>';

  /// Past the last question: the interview is over.
  static const String end = '<end>';

  final String from;
  final String to;
  final Object? fromValue;
  final List<String> firedRuleIds;
  final List<String> evaluatedRuleIds;
  final Map<String, Object?> gating;

  /// True when [from] carries postskips and none of them fired.
  final bool fellThrough;
}

/// What one simulated interview did and left behind.
class FormRun {
  FormRun({
    required this.tableName,
    required this.answers,
    required this.storedRow,
    required this.visitedFields,
    required this.route,
    required this.hops,
    required this.postskipFallThroughs,
    required this.logicTallies,
    required this.decisions,
    required this.uniqueId,
    required this.blockedBy,
    required this.unanswerable,
    required this.cannotAdvance,
    required this.deadEndRoutes,
    required this.saveError,
  });

  final String tableName;

  /// Every forward navigation, in order. Retreats and backtracks are not
  /// hops: they undo a display rather than produce one.
  final List<Hop> hops;

  /// Question -> how many times its postskips were all evaluated false and
  /// the interview carried on to the next question in sequence.
  final Map<String, int> postskipFallThroughs;

  /// Logic check id -> what happened when this interview reached it.
  final Map<String, LogicTally> logicTallies;

  /// The live answer map at the moment of saving.
  final Map<String, dynamic> answers;

  /// What was handed to the database -- `coerceForStorage`'s output, which is
  /// what a "the answer given is the answer stored" check must compare
  /// against, since dates are normalised on the way through.
  final Map<String, dynamic> storedRow;

  /// Fields the interviewer actually saw. Not the same as "answered": a
  /// question can be displayed and left blank when it is optional.
  final Set<String> visitedFields;

  /// Field names in the order navigation reached them.
  final List<String> route;

  final List<Decision> decisions;
  final String? uniqueId;

  /// Every gate message this interview saw. A block is normal -- the
  /// interviewer fixes the answer and carries on, and so does the runner.
  /// What is not normal is [cannotAdvance].
  final List<String> blockedBy;

  /// Questions with no selectable option at all -- a csv or database filter
  /// that matched nothing for the answers given. An authoring defect, and one
  /// only a run can find.
  final List<String> unanswerable;

  /// Questions no answer could get past, on the question's *own* rules --
  /// nothing to select, a value no range admits, a logic check that reads only
  /// this field. The app disables Next until the gate passes, so an
  /// interviewer here can neither move on nor finish. Reported only after a
  /// deliberately conservative answer was refused too, so a strategy drawing
  /// unlucky values does not raise it.
  final List<String> cannotAdvance;

  /// Questions where the answers *already given* closed the route -- a logic
  /// check comparing this field against another, like
  /// `vx_dose2_date <= vx_dose1_date`. Not a defect: an interviewer presses
  /// Previous and changes the earlier answer, and so does the runner. Counted
  /// rather than reported as a problem, because on a chain of such checks a
  /// random respondent abandons routes a person never would -- but a question
  /// that closes on *every* run is worth a designer's eye.
  final List<String> deadEndRoutes;

  final String? saveError;

  bool get saved => saveError == null && uniqueId != null;
}

/// Drives one interview through the field app's own engine.
///
/// Everything that decides *where the interview goes* is the production code:
/// `SurveyNavigationService` for the route, `SkipService` beneath it for the
/// branches, `LogicService` for the blocks, `AutomaticFieldService` for
/// computed values and IDs, `AnswerStorageService` and `DbService` for the
/// save. What this class adds is only the parts a widget would otherwise
/// supply -- choosing an answer, and the bookkeeping `build()` does as a side
/// effect of rendering.
///
/// ## What it mirrors rather than calls, and why that is a risk
///
/// Three behaviours live inside `QuestionView` and happen because a question
/// was *displayed*, not because anyone answered it. They are reproduced here,
/// in [_simulateDisplay], and a mirror is not the thing it mirrors: change
/// `question_views.dart` and this keeps agreeing with the version it was
/// written against. The doc comment on that method names the lines it copies,
/// which is the only defence short of driving the real widget.
class FormRunner {
  FormRunner({
    required this.surveyId,
    required this.tableName,
    required this.respondent,
    this.onSkipEvaluated,
  });

  final String surveyId;
  final String tableName;
  final VirtualRespondent respondent;

  /// Told about every skip rule the engine tries, and whether it fired.
  ///
  /// The rule is identified by [skipRuleId], which needs the question that
  /// owns it -- `SkipCondition` carries no identity of its own, and the same
  /// (field, operator, value, target) can legitimately appear twice in one
  /// form.
  final void Function(String ruleId, bool fired)? onSkipEvaluated;

  static const AppStrings _strings = AppStrings(AppConfig.isFrench);

  String get _questionnaireFilename => '$tableName.xml';

  Future<FormRun> run({
    Map<String, dynamic>? prepopulatedAnswers,
    Map<String, dynamic>? crf,
  }) async {
    // The crfs **table**, not the manifest. `_syncCrfsTable` json-encodes the
    // nested idconfig into a TEXT column on the way in, and `IdGenerator`
    // expects that JSON string. Reading the manifest's parsed Map and calling
    // toString() on it yields `{prefix: , fields: [...]}`, which is not JSON:
    // every ID then failed to validate and every record was saved with the
    // `-9` fallback, colliding on the primary key from the second row on.
    final config = crf ?? await DbService.getCrfConfig(surveyId, tableName);
    final idConfig = config?['idconfig']?.toString();
    final incrementField = config?['incrementfield']?.toString();

    // Only when this form actually has a parent, matching what
    // QuestionnaireSelectorScreen passes. `linkingField` exists to stop
    // IdGenerator overwriting a value that arrived from somewhere else; on a
    // base form the crfs `linkingfield` names the key *children* link on, and
    // passing it makes `isGeneratedIdField` refuse to generate the field the
    // idconfig is for. PRISM's hh_info names `hhid` in both, which is how this
    // was found.
    final hasParent = (config?['parenttable']?.toString() ?? '').isNotEmpty;
    final linkingField = hasParent
        ? (config?['linkingfield'])?.toString()
        : null;

    final answers = <String, dynamic>{...?prepopulatedAnswers};
    final visited = <String>{};
    final route = <String>[];
    final blocked = <String>[];
    final unanswerable = <String>[];
    final cannotAdvance = <String>[];
    final deadEndRoutes = <String>[];
    // How many times each question has sent the interviewer back. Bounded,
    // because a form really can contain a question with no way past it and
    // the run has to end either way.
    final retreats = <String, int>{};

    final assetPath = await SurveyConfigService().getQuestionnaireAssetPath(
      _questionnaireFilename,
    );
    if (assetPath == null) {
      throw StateError('No questionnaire $_questionnaireFilename in $surveyId');
    }

    final questions = await SurveyLoader.loadFromFile(File(assetPath));
    final csv = CsvDataService();
    await csv.loadAllCsvFiles(p.dirname(assetPath), questions);

    final primaryKeyFields = await DbService.getPrimaryKeyFields(
      surveyId,
      tableName,
    );

    // New records only, exactly as the screen gates it.
    await ChildIncrementService.assign(
      questions: questions,
      answers: answers,
      surveyId: surveyId,
      tableName: tableName,
      incrementField: incrementField,
      fallbackLinkingField: linkingField,
    );

    // Every rule that reads a given field, from anywhere in the form. Most
    // branching in a real dictionary is a preskip on a *later* question
    // testing an earlier answer, so a respondent steering only its own
    // question's postskips cannot influence the route at all.
    final rulesByTestedField = <String, List<SkipCondition>>{};
    // Identity-keyed, because `SkipCondition` does not override `==` and two
    // rules with the same triple must stay distinct.
    final ruleIds = <SkipCondition, String>{};
    for (final q in questions) {
      for (final rule in [...q.preSkips, ...q.postSkips]) {
        (rulesByTestedField[rule.fieldName] ??= []).add(rule);
      }
      for (var i = 0; i < q.preSkips.length; i++) {
        ruleIds[q.preSkips[i]] = skipRuleId(tableName, q, 'preskip', i);
      }
      for (var i = 0; i < q.postSkips.length; i++) {
        ruleIds[q.postSkips[i]] = skipRuleId(tableName, q, 'postskip', i);
      }
    }
    final topology = SkipTopology.of(tableName, questions);
    respondent.enterForm(tableName);

    // What the engine reported during the navigation call in progress. Reset
    // before each hop, read into the `Hop` after it.
    final firedThisHop = <String>[];
    final evaluatedThisHop = <String>[];
    final hops = <Hop>[];
    final fallThroughs = <String, int>{};
    final logicTallies = <String, LogicTally>{};
    final fieldNames = {for (final q in questions) q.fieldName};

    final observer = onSkipEvaluated;
    void watch(SkipCondition skip, bool fired) {
      final id = ruleIds[skip];
      if (id == null) return;
      evaluatedThisHop.add(id);
      if (fired) firedThisHop.add(id);
      observer?.call(id, fired);
    }

    Map<String, Object?> gatingSnapshot() => {
          for (final g in topology.gatingFields) g: answers[g],
        };

    void recordHop(String from, Object? fromValue, int nextIndex, Question? fromQuestion) {
      final to = nextIndex < 0 ||
              nextIndex >= questions.length ||
              questions[nextIndex].fieldName == SurveyLoader.endOfQuestionsField
          ? Hop.end
          : questions[nextIndex].fieldName;
      var fellThrough = false;
      if (fromQuestion != null && fromQuestion.postSkips.isNotEmpty) {
        final owned = topology.rulesOwnedBy[fromQuestion.fieldName] ?? const [];
        fellThrough = !firedThisHop.any(
          (id) => owned.any((r) => !r.isPreskip && r.id == id),
        );
        if (fellThrough) {
          fallThroughs.update(fromQuestion.fieldName, (v) => v + 1,
              ifAbsent: () => 1);
        }
      }
      hops.add(
        Hop(
          from: from,
          to: to,
          fromValue: fromValue,
          firedRuleIds: List.of(firedThisHop),
          evaluatedRuleIds: List.of(evaluatedThisHop),
          gating: gatingSnapshot(),
          fellThrough: fellThrough,
        ),
      );
      firedThisHop.clear();
      evaluatedThisHop.clear();
    }

    Future<void> processAutomatic(Question q) async {
      await AutomaticFieldService.compute(
        question: q,
        answers: answers,
        surveyId: surveyId,
        tableName: tableName,
        idConfig: idConfig,
        linkingField: linkingField,
        incrementField: incrementField,
        isEditMode: false,
      );
    }

    var index = await SurveyNavigationService.findNextDisplayedQuestion(
      questions: questions,
      startIndex: 0,
      answers: answers,
      processAutomaticQuestion: processAutomatic,
      primaryKeyFields: primaryKeyFields,
      onSkipEvaluated: watch,
    );
    recordHop(Hop.start, null, index, null);

    final history = <int>[];
    // A form cannot legitimately take more steps than it has questions plus
    // the backtracking allowed, and a runaway here would hang the app rather
    // than report anything.
    final stepBudget = questions.length * 8 + 64;

    for (var step = 0; step < stepBudget; step++) {
      if (index < 0 || index >= questions.length) break;
      final question = questions[index];

      // The end-of-survey screen the generator writes into every form.
      // Navigation stops here; anything after it is never computed.
      if (question.fieldName == SurveyLoader.endOfQuestionsField) break;

      route.add(question.fieldName);
      await _simulateDisplay(question, answers, visited, csv);

      final options = await _resolveOptions(question, answers, csv);
      final emptyList = _needsOptions(question) && options.isEmpty;
      // A list that is empty *because of earlier answers* -- a filter on
      // another field matched nothing -- is not a defect in the list. In the
      // field (PRISM's `sleptunder`: "who slept under this net", drawn from
      // the household members not yet named) it means an earlier answer was
      // wrong, and the interviewer goes back and changes it. Only a list
      // that is empty regardless of the answers is reported as unanswerable.
      if (emptyList && !_dependsOnAnswers(question)) {
        unanswerable.add(question.fieldName);
      }

      // The Next button, as the app draws it.
      //
      // `SurveyScreen` computes
      // `canProceed = (information || (isAnswered && isValid)) &&
      // _logicError == null` on every build and passes `null` to `onPressed`
      // when it is false -- so a blank non-optional answer, a value outside
      // its range, a half-typed fixed-length key or a failing `logic_check`
      // makes moving on *impossible*, not merely noisy. `_next` then adds the
      // `<unique_check>` round-trip and returns without advancing on a
      // collision. Walking past any of that would let this runner produce
      // routes the field app cannot, and would report a question an
      // interviewer is stuck on as a tally line.
      //
      // So: answer, gate, re-answer. The last few attempts ask for a
      // deliberately conservative value, because a strategy drawing unlucky
      // ones must not be mistaken for a form with no way through.
      const attempts = 25;
      const safeFrom = attempts - 5;
      var advanced = question.type == QuestionType.information;
      String? lastBlock;

      for (var attempt = 0; !advanced && !emptyList && attempt < attempts; attempt++) {
        final value = attempt < safeFrom
            ? respondent.answerFor(
                question,
                options: options,
                rulesTestingThis:
                    rulesByTestedField[question.fieldName] ?? const [],
                answers: answers,
              )
            : respondent.satisfyingAnswerFor(
                question,
                options: options,
                answers: answers,
              );

        if (value == null) {
          answers.remove(question.fieldName);
        } else {
          answers[question.fieldName] = value;
        }

        // What `_onAnswerChanged` does, for the message.
        final validation = AnswerValidationService.evaluate(
          question,
          answers,
          _strings,
        );
        // What `build` does, for the button. `evaluate` stays silent on a
        // half-typed fixed-length field, so the message and the gate can
        // disagree -- the gate is the one that decides.
        if (AnswerValidationService.canProceed(question, answers, _strings)) {
          final collision = await _uniqueCheckMessage(question, value);
          if (collision == null) {
            advanced = true;
            break;
          }
          lastBlock = collision;
        } else {
          // The app shows nothing at all for a blank or half-typed answer --
          // the button is simply dead. A report that said nothing either
          // would be useless, so name the half of the gate that failed.
          lastBlock = validation.message ??
              LogicService.evaluateLogicChecks(question, answers) ??
              (AnswerValidationService.isAnswered(question, answers)
                  ? 'the answer does not satisfy this question, '
                      'and no message is shown'
                  : 'no answer, and the question is not optional');
        }
        blocked.add('${question.fieldName}: $lastBlock');
      }

      // What each logic check saw, once per display, on the answers the
      // interviewer left. The engine evaluates on every keystroke; counting
      // each of those would weight a question by how often it was retried.
      for (var i = 0; i < question.logicChecks.length; i++) {
        final check = question.logicChecks[i];
        final id = LogicTally.idFor(tableName, question.fieldName, i, check.condition);
        final tally = logicTallies[id] ??= LogicTally();
        tally.evaluated++;
        final probe = Question(
          type: question.type,
          fieldName: question.fieldName,
          fieldType: question.fieldType,
          logicChecks: [check],
        );
        if (LogicService.evaluateLogicChecks(probe, answers) != null) tally.fired++;
        final blank = LogicTally.identifiersIn(check.condition).where(
          (f) => f != question.fieldName && fieldNames.contains(f) && answers[f] == null,
        );
        if (blank.isNotEmpty) {
          tally.nullOperand++;
          for (final f in blank) {
            tally.nullFields.update(f, (v) => v + 1, ifAbsent: () => 1);
          }
        }
      }

      if (!advanced) {
        // A gate can close for two quite different reasons, and calling both
        // a dead end would bury the one that matters.
        //
        // The question itself may be impassable -- a logic check no value
        // satisfies, a response list that resolved to nothing. Or the answers
        // *already given* may have closed it: `vx_dose2_date` must fall after
        // `vx_dose1_date`, and if dose 1 was entered as today then no date in
        // range will do. The second is not a defect in the form, and an
        // interviewer meeting it does the obvious thing -- presses Previous
        // and changes the earlier answer. So does this.
        const maxRetreats = 3;
        final taken = retreats[question.fieldName] ?? 0;
        final routeClosed = (emptyList && _dependsOnAnswers(question)) ||
            _blockedByAnotherField(question, questions, answers);
        if (history.isNotEmpty && taken < maxRetreats) {
          retreats[question.fieldName] = taken + 1;
          index = history.removeLast();
          // Going back to give the same answer again would arrive here again.
          // An interviewer changes the earlier answer; so does this. Each
          // time is counted: a question every interview has to back out of
          // is worth a designer's eye even when everyone gets through.
          if (routeClosed) {
            deadEndRoutes.add(question.fieldName);
            final previous = questions[index].fieldName;
            respondent.avoid(previous, answers[previous]);
          }
          continue;
        }
        if (routeClosed) {
          deadEndRoutes.add(question.fieldName);
        } else {
          cannotAdvance.add(question.fieldName);
        }
      }

      if (respondent.shouldBacktrack(history.length)) {
        index = history.removeLast();
        continue;
      }

      if (question.type != QuestionType.automatic) history.add(index);

      firedThisHop.clear();
      evaluatedThisHop.clear();
      final next = await SurveyNavigationService.advanceFromQuestion(
        questions: questions,
        currentIndex: index,
        answers: answers,
        processAutomaticQuestion: processAutomatic,
        primaryKeyFields: primaryKeyFields,
        onSkipEvaluated: watch,
      );
      // Parked on the last question means the walk ran off the end.
      recordHop(
        question.fieldName,
        answers[question.fieldName],
        next == index ? questions.length : next,
        question,
      );

      if (next == index) break;
      index = next;
    }

    // The save path, in the order `_showDone` performs it.
    AnswerStorageService.clearSkippedAnswers(
      answers: answers,
      questions: questions,
      visitedFields: visited,
      primaryKeyFields: primaryKeyFields,
    );
    AutoFields.touchLastMod(answers);
    final storedRow = AnswerStorageService.coerceForStorage(answers, questions);

    String? saveError;
    try {
      await DbService.saveInterview(
        surveyId: surveyId,
        surveyFilename: _questionnaireFilename,
        answers: storedRow,
      );
    } catch (e) {
      saveError = e.toString();
    }

    return FormRun(
      tableName: tableName,
      answers: answers,
      storedRow: storedRow,
      visitedFields: visited,
      route: route,
      hops: hops,
      postskipFallThroughs: fallThroughs,
      logicTallies: logicTallies,
      decisions: List.of(respondent.decisions),
      uniqueId: storedRow['uniqueid']?.toString(),
      blockedBy: blocked,
      unanswerable: unanswerable,
      cannotAdvance: cannotAdvance,
      deadEndRoutes: deadEndRoutes,
      saveError: saveError,
    );
  }

  /// Whether what is blocking [question] is an answer given somewhere else.
  ///
  /// The two cases need telling apart or the useful one drowns. A question
  /// with nothing to select, or a range no value satisfies, is closed for
  /// everybody. A logic check reading a *second* field --
  /// `vx_dose2_date <= vx_dose1_date`, `age <> age_calculated` -- is closed
  /// only for the answers this interview happens to hold, and a person just
  /// goes back and changes them.
  ///
  /// Deliberately coarse: it asks whether the question is answered and valid
  /// on its own terms and still blocked, and whether any of its logic checks
  /// name another field of this form. Deciding *which* check failed would
  /// mean re-implementing `LogicService`'s grammar, and this does not need to
  /// know.
  bool _blockedByAnotherField(
    Question question,
    List<Question> questions,
    Map<String, dynamic> answers,
  ) {
    if (!AnswerValidationService.isAnswered(question, answers)) return false;
    if (!AnswerValidationService.isValid(question, answers)) return false;
    if (LogicService.evaluateLogicChecks(question, answers) == null) {
      return false;
    }

    final others = {
      for (final q in questions)
        if (q.fieldName != question.fieldName) q.fieldName,
    };
    final identifier = RegExp(r'[A-Za-z_]\w*');
    return question.logicChecks.any(
      (check) => identifier
          .allMatches(check.condition)
          .any((m) => others.contains(m.group(0))),
    );
  }

  /// The `<unique_check>` round-trip `SurveyScreen._next` makes on the way
  /// past, or null when the value is free.
  ///
  /// New records only, so there is no `_originalAnswers` to compare against:
  /// every value here is a change. A mask -- or the free-text pool -- too
  /// small to stay unique across this many records is a fact about the
  /// survey, and the caller's attempt bound is what stops it looping.
  Future<String?> _uniqueCheckMessage(Question question, Object? value) async {
    if (question.uniqueCheck == null || value == null || '$value'.isEmpty) {
      return null;
    }
    final isUnique = await DbService.isValueUnique(
      surveyId,
      tableName,
      question.fieldName,
      '$value',
    );
    if (isUnique) return null;
    return question.uniqueCheck!.message ?? _strings.valueAlreadyExists;
  }

  /// A stable name for one skip rule, for coverage.
  ///
  /// Owner and position are part of it because `SkipCondition` carries no
  /// identity and the same (field, operator, value, target) can legitimately
  /// appear on two questions -- or twice on one, once as a preskip and once
  /// as a postskip.
  static String skipRuleId(
    String table,
    Question owner,
    String kind,
    int order,
  ) {
    final rule = kind == 'preskip'
        ? owner.preSkips[order]
        : owner.postSkips[order];
    return RuleRef.idFor(table, owner.fieldName, kind, order, rule);
  }

  /// Reproduces what happens because a question is rendered.
  ///
  /// Mirrors `question_views.dart` (`QuestionView.initState`, roughly lines
  /// 62-160) and `survey_screen.dart:740`. Three things happen there that no
  /// service does, and a record differs without them:
  ///
  /// * **visitation** is recorded in `build`, not in `_next`, so a question is
  ///   "visited" by being rendered for one frame. It is add-only -- nothing
  ///   ever removes from it -- so a question displayed on a branch that is
  ///   later abandoned still counts as visited and its answer is not cleared.
  /// * **a masked text question writes its mask prefix** into the answer map
  ///   merely by appearing, so "displayed but never typed in" is not the same
  ///   as blank.
  /// * **anything carrying a `<calculation>` is computed here**, including a
  ///   plain text or date question. `SurveyNavigationService` routes only
  ///   `automatic` questions through the callback, so for those this is the
  ///   only place the value is ever produced.
  Future<void> _simulateDisplay(
    Question question,
    Map<String, dynamic> answers,
    Set<String> visited,
    CsvDataService csv,
  ) async {
    if (question.type != QuestionType.automatic) {
      visited.add(question.fieldName);
    }

    if (question.calculation != null) {
      await AutoFields.compute(answers, question, surveyId: surveyId);
    }
  }

  /// Whether the question's list is filtered on other answers, so that an
  /// empty list can be the route's fault rather than the list's.
  bool _dependsOnAnswers(Question question) {
    final config = question.responseConfig;
    if (config == null) return false;
    return config.filters.any((f) => f.value.contains('[['));
  }

  bool _needsOptions(Question question) =>
      question.type == QuestionType.radio ||
      question.type == QuestionType.checkbox ||
      question.type == QuestionType.combobox;

  Future<List<QuestionOption>> _resolveOptions(
    Question question,
    Map<String, dynamic> answers,
    CsvDataService csv,
  ) async {
    final config = question.responseConfig;
    if (config == null) return question.options;

    try {
      if (config.source == ResponseSource.csv) {
        return await csv.getResponseOptions(config, answers);
      }
      if (config.source == ResponseSource.database) {
        return await DatabaseResponseService.getResponseOptions(
          surveyId,
          config,
          answers,
        );
      }
    } catch (_) {
      // A filter that matched nothing, or a table that is not there. Recorded
      // by the caller as unanswerable rather than thrown -- it is a finding
      // about the dictionary, not a crash.
      return const [];
    }
    return question.options;
  }
}
