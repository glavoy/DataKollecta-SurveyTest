import 'dart:math';

import 'package:datakollecta/models/question.dart';
import 'package:datakollecta/services/field_comparator.dart';
import 'package:datakollecta/services/numeric_validation_service.dart';

import 'mask.dart';
import 'steering.dart';

/// How a simulated interviewer chooses answers.
enum RespondentStrategy {
  /// Uniform over whatever is legal. The workhorse.
  random,

  /// Always the first option, the lowest number, the earliest date. Produces
  /// the same route every time, which makes it the one to reach for when
  /// reproducing a report by hand.
  firstOption,

  /// Range ends and the values either side of them. Where off-by-one lives.
  boundaryValues,

  /// Prefers the answer that makes a skip fire, so branches get taken rather
  /// than merely existing.
  skipMaximising,

  /// Prefers the answer that makes no skip fire, walking the long way through
  /// the form.
  skipAvoiding,

  /// Answers "don't know" or "refuse" wherever the question offers it. These
  /// are stored as codes outside the response list and bypass the range check,
  /// so they reach code ordinary answers do not.
  dontKnowHeavy,
}

/// One decision, kept so a failing run can be read back.
class Decision {
  const Decision(this.fieldName, this.value, this.note);
  final String fieldName;
  final Object? value;
  final String note;

  @override
  String toString() => '$fieldName = ${value ?? '(blank)'}  [$note]';
}

/// Chooses answers the way an interviewer's fingers would leave them.
///
/// The values here have to match what the **widget layer** stores, not what
/// would be tidy. A date question holds a `DateTime` because that is what the
/// picker writes; a checkbox holds a `List<String>`; a fixed-length numeric is
/// zero-padded because `QuestionView` pads it on seed. Getting any of those
/// wrong makes every "the answer that was given is the answer that was stored"
/// check fail for a reason that is about the simulator, not the survey.
class VirtualRespondent {
  VirtualRespondent({
    required int seed,
    this.strategy = RespondentStrategy.random,
    this.optionalBlankRate = 0.2,
    this.specialResponseRate = 0.05,
    this.backtrackRate = 0.0,
    this.targets = const {},
  }) : _random = Random(seed),
       _seed = seed;

  final Random _random;
  final int _seed;
  final RespondentStrategy strategy;

  /// Table -> field -> what a steered interview needs that field to satisfy.
  ///
  /// A steered respondent answers a targeted field with the first value that
  /// meets every constraint, once, on the first attempt at the question; if
  /// a gate refuses that value it falls back to its strategy, so a steer can
  /// never manufacture a `cannot_advance`. Whether the steer *worked* is not
  /// decided here -- the engine's own skip observer says whether the rule
  /// fired, and that is what the report reads.
  final Map<String, Map<String, List<SteerConstraint>>> targets;

  String _table = '';
  final Set<String> _steeredOnce = {};

  /// Fields steering chose a value for, and what it chose. Read by the
  /// session so a failed steer can say what was tried.
  final Map<String, Object?> steeredValues = {};

  /// Fields where no candidate satisfied every constraint.
  final Set<String> steerFailed = {};

  /// Values not to give again: the runner went back to this question because
  /// the answer it held closed the route ahead, and an interviewer who goes
  /// back changes the answer rather than repeating it.
  final Map<String, Set<String>> _avoid = {};

  void avoid(String field, Object? value) {
    final text = FieldComparator.resolveText(value);
    if (text == null) return;
    (_avoid[field] ??= {}).add(text);
  }

  /// Called by `FormRunner` when an interview on [table] begins, so
  /// [targets] are read for the right form.
  void enterForm(String table) {
    _table = table;
    _steeredOnce.clear();
  }

  /// How often a question the dictionary marked optional is left blank. The
  /// one legitimate way a displayed question ends up NULL.
  final double optionalBlankRate;

  /// How often "don't know"/"refuse" is chosen where offered, outside
  /// [RespondentStrategy.dontKnowHeavy].
  final double specialResponseRate;

  /// How often the interviewer goes back a question before carrying on. Going
  /// back and forward again is how a record's answers get recomputed, and is
  /// the only way to reach some of what the engine does.
  final double backtrackRate;

  final List<Decision> decisions = [];

  int get seed => _seed;

  bool roll(double probability) => _random.nextDouble() < probability;

  /// Whether to step back a question rather than forward.
  bool shouldBacktrack(int historyDepth) =>
      historyDepth > 0 && roll(backtrackRate);

  /// The value to store for [question], or null to leave it blank.
  ///
  /// [options] are the resolved choices -- static ones come off the question,
  /// CSV- and database-backed ones are looked up first, so this never has to
  /// know where they came from.
  /// [rulesTestingThis] are every skip rule anywhere in the form that reads
  /// this field. The skip strategies need them because most real branching is
  /// not a postskip on the question being answered: it is a **preskip on a
  /// later question** testing this one -- `preskip: if enrolled = 1, skip to
  /// swater`. Without them the strategies could steer only the small minority
  /// of rules attached to their own question, and skip-maximising and
  /// skip-avoiding produced identical routes on a real dictionary.
  Object? answerFor(
    Question question, {
    required List<QuestionOption> options,
    List<SkipCondition> rulesTestingThis = const [],
    Map<String, dynamic> answers = const {},
  }) {
    final constraints = targets[_table]?[question.fieldName];
    if (constraints != null &&
        constraints.isNotEmpty &&
        _steeredOnce.add(question.fieldName)) {
      final steered = _steer(question, options, constraints, answers);
      if (steered != null) {
        steeredValues[question.fieldName] = steered.value;
        decisions.add(Decision(question.fieldName, steered.value, 'steered'));
        return steered.value;
      }
      steerFailed.add(question.fieldName);
    }

    final avoided = _avoid[question.fieldName];
    final usable = avoided == null
        ? options
        : options.where((o) => !avoided.contains(o.value)).toList();
    // Only narrow the list when something is left to choose from.
    final value = _choose(
      question,
      usable.isEmpty ? options : usable,
      rulesTestingThis,
    );
    if (avoided != null && FieldComparator.resolveText(value) != null &&
        avoided.contains(FieldComparator.resolveText(value)) &&
        usable.isNotEmpty) {
      // A strategy that ignores the option list (numeric, free text) may
      // still repeat itself; a second draw is cheap and usually enough.
      final again = _choose(question, usable, rulesTestingThis);
      decisions.add(Decision(question.fieldName, again, '${strategy.name}, changed'));
      return again;
    }
    decisions.add(Decision(question.fieldName, value, strategy.name));
    return value;
  }

  /// The first candidate answer that satisfies every constraint, or null.
  ///
  /// Candidates are what an interviewer could actually enter for this
  /// question -- its options, values inside its range, its Don't-know and
  /// Refuse codes, a blank only where the question is optional -- and each is
  /// judged through `FieldComparator`, the app's own comparison. A blank is
  /// tried last: it satisfies a "must not fire" constraint only by the
  /// fail-open rule, and a value that keeps the rule from firing on its
  /// merits is a stronger test.
  _Steered? _steer(
    Question question,
    List<QuestionOption> options,
    List<SteerConstraint> constraints,
    Map<String, dynamic> answers,
  ) {
    for (final candidate in _steerCandidates(question, options, constraints)) {
      if (constraints.every((c) => c.satisfiedBy(candidate, answers))) {
        return _Steered(candidate);
      }
    }
    if (question.optional &&
        constraints.every((c) => c.satisfiedBy(null, answers))) {
      return const _Steered(null);
    }
    return null;
  }

  Iterable<Object?> _steerCandidates(
    Question question,
    List<QuestionOption> options,
    List<SteerConstraint> constraints,
  ) sync* {
    final specials = <String>[
      if (question.dontKnow != null && question.dontKnow!.isNotEmpty)
        question.dontKnow!,
      if (question.refuse != null && question.refuse!.isNotEmpty)
        question.refuse!,
    ];
    final literals = [
      for (final c in constraints)
        if (!c.isDynamic) c.response,
    ];

    switch (question.type) {
      case QuestionType.radio:
      case QuestionType.combobox:
        // The loader has already appended Don't-know/Refuse to a static list.
        for (final o in options) {
          yield o.value;
        }
        for (final s in specials) {
          if (!options.any((o) => o.value == s)) yield s;
        }
        return;

      case QuestionType.checkbox:
        for (final o in options) {
          yield [o.value];
        }
        if (options.length > 1) {
          yield [for (final o in options) o.value];
          for (final o in options) {
            yield [for (final other in options) if (other != o) other.value];
          }
        }
        for (final s in specials) {
          yield [s];
        }
        return;

      case QuestionType.date:
      case QuestionType.datetime:
        final min =
            question.minDate ??
            DateTime.now().subtract(const Duration(days: 36500));
        final max = question.maxDate ?? DateTime.now();
        final span = max.difference(min).inDays;
        yield min;
        yield max;
        if (span > 1) yield min.add(Duration(days: span ~/ 2));
        for (final lit in literals) {
          final d = DateTime.tryParse(lit);
          if (d == null) continue;
          for (final v in [d, d.subtract(const Duration(days: 1)), d.add(const Duration(days: 1))]) {
            if (!v.isBefore(min) && !v.isAfter(max)) yield v;
          }
        }
        for (final s in specials) {
          yield s;
        }
        return;

      case QuestionType.text:
        final check = question.numericCheck;
        final isNumeric =
            question.fieldType == 'text_integer' ||
            question.fieldType == 'text_decimal' ||
            check != null;
        if (isNumeric) {
          final min = (check?.minValue ?? 0).toInt();
          final max = (check?.maxValue ?? (min + 100)).toInt();
          final candidates = <int>{
            min,
            min + 1,
            (min + max) ~/ 2,
            max - 1,
            max,
            for (final lit in literals) ...[
              if (int.tryParse(lit) != null) ...[
                int.parse(lit),
                int.parse(lit) - 1,
                int.parse(lit) + 1,
              ],
            ],
          }.where((v) => v >= min && v <= max).where(
                (v) => check == null || NumericValidationService.isWithinRange(check, v),
              );
          for (final v in candidates) {
            yield question.fieldType == 'text_decimal' ? '$v.0' : _pad(question, '$v');
          }
          for (final s in specials) {
            yield s;
          }
          return;
        }
        // Free text: the literal itself makes an equality fire; a word that
        // is not any literal makes it not fire.
        for (final lit in literals) {
          yield _cap(question, lit);
        }
        yield _cap(question, _freeTextValue(question));
        yield _cap(question, 'zz');
        return;

      case QuestionType.information:
      case QuestionType.automatic:
        return;
    }
  }

  /// A deliberately conservative answer: the one most likely to satisfy the
  /// question's own rules.
  ///
  /// `FormRunner` blocks on a failed gate and re-asks, exactly as the app
  /// refuses to advance. That raises a question: after N refusals, is the
  /// question genuinely impassable, or did the strategy just keep drawing
  /// unlucky values? This is the answer -- on its last attempts the runner
  /// asks for this instead, and only reports a dead end when even this is
  /// refused. Nothing here is random beyond the free-text pool: no optional
  /// blank, no "don't know", the middle of a range rather than its ends, and
  /// the first option of a list.
  Object? satisfyingAnswerFor(
    Question question, {
    required List<QuestionOption> options,
    required Map<String, dynamic> answers,
  }) {
    final value = _satisfying(question, options, answers);
    decisions.add(Decision(question.fieldName, value, 'satisfying'));
    return value;
  }

  Object? _satisfying(
    Question question,
    List<QuestionOption> options,
    Map<String, dynamic> answers,
  ) {
    final mirrored = _verificationTarget(question, answers);
    if (mirrored != null) return mirrored;

    switch (question.type) {
      case QuestionType.radio:
      case QuestionType.combobox:
        return options.isEmpty ? null : options.first.value;

      case QuestionType.checkbox:
        return options.isEmpty ? null : [options.first.value];

      case QuestionType.date:
      case QuestionType.datetime:
        final min =
            question.minDate ??
            DateTime.now().subtract(const Duration(days: 36500));
        final max = question.maxDate ?? DateTime.now();
        if (max.isBefore(min)) return min;
        // One end or the other, varying between attempts. Ordering checks are
        // what dates carry -- `vx_dose2_date <= vx_dose1_date`,
        // `vx_dose2_date < dob` -- and every one of those is satisfied by an
        // end of the range rather than by anything in between. Solving them
        // properly would mean a constraint solver over `LogicService`'s
        // grammar; trying both ends is what an interviewer does.
        final span = max.difference(min).inDays;
        switch (_random.nextInt(3)) {
          case 0:
            return max;
          case 1:
            return min;
          default:
            return min.add(Duration(days: span ~/ 2));
        }

      case QuestionType.text:
        final check = question.numericCheck;
        final isNumeric =
            question.fieldType == 'text_integer' ||
            question.fieldType == 'text_decimal' ||
            check != null;
        if (!isNumeric) return _pickFreeText(question);

        final min = (check?.minValue ?? 0).toInt();
        final max = (check?.maxValue ?? (min + 100)).toInt();
        final mid = max < min ? min : min + (max - min) ~/ 2;
        if (question.fieldType == 'text_decimal') return '$mid.0';
        return _pad(question, '$mid');

      case QuestionType.information:
      case QuestionType.automatic:
        return null;
    }
  }

  /// The value a "re-enter it to confirm" question is asking for.
  ///
  /// A verification field is written as a logic check that fails when the two
  /// disagree -- `barcode2 <> barcode`, `hhid_manual <> hhid`. An interviewer
  /// types the matching value and moves on; a respondent drawing at random
  /// never will, and would have the runner report a question every real
  /// interview gets past as a dead end.
  ///
  /// Deliberately narrow: only a bare `thisField <> otherField`, with the
  /// other field already answered. Anything with an `and`, an `or`, a literal
  /// or parentheses is left alone rather than half-understood -- `LogicService`
  /// owns that grammar and this is not a second copy of it.
  static final _verification = RegExp(
    r'^\s*(\w+)\s*(?:<>|!=)\s*(\w+)\s*$',
  );

  String? _verificationTarget(Question question, Map<String, dynamic> answers) {
    for (final check in question.logicChecks) {
      final match = _verification.firstMatch(check.condition);
      if (match == null) continue;

      final left = match.group(1)!;
      final right = match.group(2)!;
      final other = left == question.fieldName
          ? right
          : (right == question.fieldName ? left : null);
      if (other == null) continue;

      final value = answers[other];
      if (value == null || '$value'.isEmpty) continue;
      return '$value';
    }
    return null;
  }

  Object? _choose(
    Question question,
    List<QuestionOption> options,
    List<SkipCondition> rulesTestingThis,
  ) {
    if (question.optional && roll(optionalBlankRate)) return null;

    final special = _specialResponse(question);
    if (special != null) return special;

    switch (question.type) {
      case QuestionType.radio:
      case QuestionType.combobox:
        return _pickOption(question, options, rulesTestingThis);

      case QuestionType.checkbox:
        return _pickSubset(options);

      case QuestionType.date:
      case QuestionType.datetime:
        return _pickDate(question);

      case QuestionType.text:
        return _pickText(question, rulesTestingThis);

      // Neither stores anything: information displays copy, automatic is
      // computed by the engine when navigation reaches it.
      case QuestionType.information:
      case QuestionType.automatic:
        return null;
    }
  }

  /// "Don't know" and "Refuse" are stored as their own codes, which are not in
  /// the Responses list and are exempt from the range check. Worth reaching
  /// deliberately rather than by luck.
  String? _specialResponse(Question question) {
    final codes = [
      if (question.dontKnow != null && question.dontKnow!.isNotEmpty)
        question.dontKnow!,
      if (question.refuse != null && question.refuse!.isNotEmpty)
        question.refuse!,
    ];
    if (codes.isEmpty) return null;

    final rate = strategy == RespondentStrategy.dontKnowHeavy
        ? 0.6
        : specialResponseRate;
    return roll(rate) ? codes[_random.nextInt(codes.length)] : null;
  }

  String? _pickOption(
    Question question,
    List<QuestionOption> options,
    List<SkipCondition> rulesTestingThis,
  ) {
    if (options.isEmpty) return null;

    switch (strategy) {
      case RespondentStrategy.firstOption:
        return options.first.value;
      case RespondentStrategy.boundaryValues:
        return roll(0.5) ? options.first.value : options.last.value;
      case RespondentStrategy.skipMaximising:
      case RespondentStrategy.skipAvoiding:
        return _optionBySkipPreference(options, rulesTestingThis);
      case RespondentStrategy.random:
      case RespondentStrategy.dontKnowHeavy:
        return options[_random.nextInt(options.length)].value;
    }
  }

  /// Picks the option that does (or does not) make some rule reading this
  /// field fire.
  ///
  /// Cheap because skip evaluation is a pure comparison: each candidate is
  /// tested against the rule directly rather than by running the engine.
  String _optionBySkipPreference(
    List<QuestionOption> options,
    List<SkipCondition> rulesTestingThis,
  ) {
    final rules = rulesTestingThis
        .where((s) => s.responseType != 'dynamic')
        .toList();
    if (rules.isEmpty) return options[_random.nextInt(options.length)].value;

    final wanted = strategy == RespondentStrategy.skipMaximising;
    final matching = options
        .where((o) => rules.any((r) => _wouldFire(r, o.value)) == wanted)
        .toList();
    if (matching.isEmpty) return options[_random.nextInt(options.length)].value;
    return matching[_random.nextInt(matching.length)].value;
  }

  /// Whether [candidate] would make [rule] fire -- through the app's own
  /// comparator, so a `contains` rule on a checkbox and an entity-encoded
  /// operator behave here exactly as they do in the field.
  bool _wouldFire(SkipCondition rule, String candidate) =>
      FieldComparator.compare(candidate, rule.condition, rule.response);

  /// A checkbox stores a list. "Don't know"/"Refuse"/"Not in this list" are
  /// mutually exclusive with real choices, which is how the widget behaves.
  List<String>? _pickSubset(List<QuestionOption> options) {
    if (options.isEmpty) return null;
    if (strategy == RespondentStrategy.firstOption) {
      return [options.first.value];
    }
    final picked = options.where((_) => roll(0.4)).map((o) => o.value).toList();
    if (picked.isEmpty) {
      return [options[_random.nextInt(options.length)].value];
    }
    return picked;
  }

  /// A `DateTime`, because that is what the picker writes into the map.
  DateTime? _pickDate(Question question) {
    final min =
        question.minDate ??
        DateTime.now().subtract(const Duration(days: 36500));
    final max = question.maxDate ?? DateTime.now();
    if (max.isBefore(min)) return min;

    switch (strategy) {
      case RespondentStrategy.firstOption:
        return min;
      case RespondentStrategy.boundaryValues:
        return roll(0.5) ? min : max;
      default:
        final span = max.difference(min).inDays;
        return span <= 0 ? min : min.add(Duration(days: _random.nextInt(span)));
    }
  }

  String? _pickText(
    Question question,
    List<SkipCondition> rulesTestingThis,
  ) {
    final check = question.numericCheck;
    final isNumeric =
        question.fieldType == 'text_integer' ||
        question.fieldType == 'text_decimal' ||
        check != null;

    if (!isNumeric) return _pickFreeText(question);

    final min = (check?.minValue ?? 0).toInt();
    final max = (check?.maxValue ?? (min + 100)).toInt();
    final value =
        _numberBySkipPreference(min, max, rulesTestingThis) ??
        _pickNumberIn(min, max);

    if (question.fieldType == 'text_decimal') {
      // Never a trailing '.', which is the half-typed state the app blocks --
      // reachable deliberately in a targeted test, never by accident here.
      return '$value.${_random.nextInt(10)}';
    }
    return _pad(question, '$value');
  }

  /// The numeric counterpart of [_optionBySkipPreference].
  ///
  /// Without this, `skipMaximising` and `skipAvoiding` could steer only
  /// questions with a Responses list -- so a branch hanging off
  /// `preskip: if age_years >= 1` was reached only when a uniform draw over
  /// 0..99 happened to land on 0, and a report would call the question it
  /// guards "never reached" on the strength of nothing but bad luck.
  ///
  /// Returns null when the strategy is not steering, or when nothing in range
  /// gives the wanted outcome -- the caller then draws as usual.
  int? _numberBySkipPreference(
    int min,
    int max,
    List<SkipCondition> rulesTestingThis,
  ) {
    if (strategy != RespondentStrategy.skipMaximising &&
        strategy != RespondentStrategy.skipAvoiding) {
      return null;
    }
    final rules = rulesTestingThis
        .where((s) => s.responseType != 'dynamic')
        .toList();
    if (rules.isEmpty || max < min) return null;

    // The values a boundary condition can turn on, plus a few draws so the
    // choice is not always the same one. Enumerating the whole range would be
    // 100 comparisons per question for no extra reach.
    final candidates = <int>{
      min,
      min + 1,
      (min + max) ~/ 2,
      max - 1,
      max,
      for (final rule in rules) ...[
        int.tryParse(rule.response) ?? min,
        (int.tryParse(rule.response) ?? min) - 1,
        (int.tryParse(rule.response) ?? min) + 1,
      ],
      for (var i = 0; i < 3; i++) min + _random.nextInt(max - min + 1),
    }.where((v) => v >= min && v <= max).toList();

    final wanted = strategy == RespondentStrategy.skipMaximising;
    final matching = candidates
        .where((v) => rules.any((r) => _wouldFire(r, '$v')) == wanted)
        .toList();
    if (matching.isEmpty) return null;
    return matching[_random.nextInt(matching.length)];
  }

  int _pickNumberIn(int min, int max) {
    if (max < min) return min;
    switch (strategy) {
      case RespondentStrategy.firstOption:
        return min;
      case RespondentStrategy.boundaryValues:
        final candidates = <int>{
          min,
          min + 1,
          (min + max) ~/ 2,
          max - 1,
          max,
        }.where((v) => v >= min && v <= max).toList();
        return candidates[_random.nextInt(candidates.length)];
      default:
        return min + _random.nextInt(max - min + 1);
    }
  }

  /// Whether a value is unique against the database is for `FormRunner` to
  /// ask -- it is the one holding the connection, and `<unique_check>` is
  /// enforced by blocking navigation and re-asking, the same as any other
  /// logic check, rather than by this respondent quietly never offering a
  /// value twice.
  String _pickFreeText(Question question) => _pad(question, _freeTextValue(question));

  String _freeTextValue(Question question) {
    final mask = question.mask;
    if (mask != null && mask.isNotEmpty) return _cap(question, _maskedValue(mask));

    const words = [
      'Kampala',
      'Mukono',
      'Nabweru',
      'Kira',
      'Bweyogerere',
      'not stated',
      'other',
      'none',
      'n/a',
    ];
    return _cap(question, words[_random.nextInt(words.length)]);
  }

  /// Mirrors `LengthLimitingTextInputFormatter(maxCharacters)`, which the
  /// field carries whenever `<maxCharacters>` is set.
  ///
  /// The mask path needs this as much as the word list does, and used to
  /// bypass it. `OP-[0-9][0-9][0-9][0-9][0-9][0-9][0-9]` beside
  /// `<maxCharacters>=7</maxCharacters>` fills ten slots, but the real field
  /// stops accepting input at seven -- so an uncapped value was a string no
  /// interviewer could ever have typed, and one that could never satisfy the
  /// fixed-length rule the same declaration imposes.
  String _cap(Question question, String text) {
    final max = question.maxCharacters;
    if (max == null || text.length <= max) return text;
    return text.substring(0, max);
  }

  /// Builds a value satisfying [mask], slot by slot: `[...]` is a character
  /// class (as `MaskedTextInputFormatter` reads it, so a generated value is
  /// exactly what the real input field would accept), anything else is a
  /// literal carried through unchanged.
  static const _maskAlphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  String _maskedValue(String mask) {
    final buffer = StringBuffer();
    for (final slot in Mask(mask).slots) {
      final charClass = slot.charClass;
      if (charClass == null) {
        buffer.write(slot.literal);
        continue;
      }
      final pattern = RegExp('[$charClass]');
      final candidates = [
        for (final c in _maskAlphabet.split('')) if (pattern.hasMatch(c)) c,
      ];
      buffer.write(
        candidates.isEmpty ? '0' : candidates[_random.nextInt(candidates.length)],
      );
    }
    return buffer.toString();
  }

  /// Mirrors `QuestionView._normalizeValue`: a fixed-length numeric answer is
  /// left-padded with zeros to its declared width, and the padded form is what
  /// reaches the database.
  String _pad(Question question, String value) {
    final max = question.maxCharacters;
    if (!question.fixedLength || max == null) return value;
    if (int.tryParse(value) == null) return value;
    return value.padLeft(max, '0');
  }
}

/// A steering result that distinguishes "chose a blank" from "found nothing".
class _Steered {
  const _Steered(this.value);
  final Object? value;
}
