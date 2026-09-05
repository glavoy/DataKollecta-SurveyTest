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

import 'virtual_respondent.dart';

/// What one simulated interview did and left behind.
class FormRun {
  FormRun({
    required this.tableName,
    required this.answers,
    required this.storedRow,
    required this.visitedFields,
    required this.route,
    required this.decisions,
    required this.uniqueId,
    required this.blockedBy,
    required this.unanswerable,
    required this.saveError,
  });

  final String tableName;

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

  /// Questions whose logic check refused to let navigation past. A real
  /// interviewer would fix the answer; the simulator records and moves on.
  final List<String> blockedBy;

  /// Questions with no selectable option at all -- a csv or database filter
  /// that matched nothing for the answers given. An authoring defect, and one
  /// only a run can find.
  final List<String> unanswerable;

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
  });

  final String surveyId;
  final String tableName;
  final VirtualRespondent respondent;

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
    for (final q in questions) {
      for (final rule in [...q.preSkips, ...q.postSkips]) {
        (rulesByTestedField[rule.fieldName] ??= []).add(rule);
      }
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
    );

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
      if (_needsOptions(question) && options.isEmpty) {
        unanswerable.add(question.fieldName);
      }

      if (question.type != QuestionType.information) {
        final value = respondent.answerFor(
          question,
          options: options,
          rulesTestingThis: rulesByTestedField[question.fieldName] ?? const [],
        );
        if (value == null) {
          answers.remove(question.fieldName);
        } else {
          answers[question.fieldName] = value;
        }

        final validation = AnswerValidationService.evaluate(
          question,
          answers,
          _strings,
        );
        if (validation.message != null) {
          blocked.add('${question.fieldName}: ${validation.message}');
        }
      }

      final logicError = LogicService.evaluateLogicChecks(question, answers);
      if (logicError != null) {
        blocked.add('${question.fieldName}: $logicError');
      }

      if (respondent.shouldBacktrack(history.length)) {
        index = history.removeLast();
        continue;
      }

      if (question.type != QuestionType.automatic) history.add(index);

      final next = await SurveyNavigationService.advanceFromQuestion(
        questions: questions,
        currentIndex: index,
        answers: answers,
        processAutomaticQuestion: processAutomatic,
        primaryKeyFields: primaryKeyFields,
      );

      // Parked on the last question means the walk ran off the end.
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
      decisions: List.of(respondent.decisions),
      uniqueId: storedRow['uniqueid']?.toString(),
      blockedBy: blocked,
      unanswerable: unanswerable,
      saveError: saveError,
    );
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
