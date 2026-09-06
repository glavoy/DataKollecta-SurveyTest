import 'dart:io';

import 'package:datakollecta/models/question.dart';
import 'package:datakollecta/services/csv_data_service.dart';
import 'package:datakollecta/services/field_comparator.dart';
import 'package:datakollecta/services/logic_service.dart';
import 'package:datakollecta/services/survey_loader.dart';
import 'package:path/path.dart' as p;

import '../installer.dart';
import '../sim/report.dart';
import '../sim/skip_topology.dart';

/// What the package says about itself, before anyone answers a question.
///
/// SurveyGen owns everything that can be decided from the dictionary and the
/// csv files alone -- operators the app does not know, literals that are not
/// codes, csv columns, date ranges, mask lengths, fields redefined across
/// forms. What stays here is what needs the engine's own code to decide: a
/// logic check parsed by the real `LogicService`, a csv cascade resolved by
/// the real `CsvDataService`, a `<skip>` the real loader drops, and how the
/// rules on a question route the codes the field also accepts. Everything is
/// deterministic and cheap, so it runs first and its findings carry no seed
/// -- there is no interview to replay, only a line in the dictionary.
///
/// Nothing here re-implements the engine. Each check hands the same object
/// the field app would hold to the same service the field app would call:
/// `FieldComparator.compare` for "does this rule fire on this value",
/// `LogicService.evaluateLogicChecks` for "does this expression parse",
/// `CsvDataService.getResponseOptions` for "what would the list show".
class PackageLint {
  const PackageLint();

  /// Beyond this many parent-value combinations a cascade is sampled rather
  /// than enumerated, and the finding says so.
  static const int cascadeCap = 2000;

  /// Integer ranges wider than this are not enumerated for domain coverage.
  static const int rangeCap = 1000;

  static const String malformedPrefix = 'Error in logic check expression';

  Future<List<Finding>> run(InstalledPackage pkg) async {
    final findings = <Finding>[];
    final forms = <_Form>[];
    final csv = CsvDataService();
    final csvMissing = <String>{};

    for (final crf in pkg.crfs) {
      final table = crf['tablename']?.toString() ?? '';
      if (table.isEmpty) continue;
      final file = File(p.join(pkg.surveyDir.path, '$table.xml'));
      if (!file.existsSync()) continue;
      final questions = await SurveyLoader.loadFromFile(file);
      forms.add(
        _Form(
          table: table,
          questions: questions,
          topology: SkipTopology.of(table, questions),
          rawXml: file.readAsStringSync(),
          linkingField: crf['linkingfield']?.toString() ?? '',
        ),
      );
      for (final q in questions) {
        final name = q.responseConfig?.file;
        if (q.responseConfig?.source != ResponseSource.csv || name == null) {
          continue;
        }
        try {
          await csv.loadCsvFile(pkg.surveyDir.path, name);
        } catch (_) {
          if (csvMissing.add(name)) {
            findings.add(
              Finding(
                code: 'csv_file_missing',
                table: table,
                field: q.fieldName,
                detail: 'reads $name, which is not in the package.',
              ),
            );
          }
        }
      }
    }

    for (final form in forms) {
      final cascades = await _cascades(form, csv, pkg.surveyDir, csvMissing, findings);
      findings
        ..addAll(_skipDomainGaps(form, cascades))
        ..addAll(_specialRoutedAsValue(form))
        ..addAll(_logicMalformed(form))
        ..addAll(_droppedSkips(form));
    }
    return findings;
  }

  // ---------------------------------------------------------------- domains

  /// Every value a field can hold, split into the answers the question offers
  /// and the codes it also accepts -- Don't know, Refuse, and a blank when
  /// the question is optional. Null when the field cannot be enumerated.
  _Domain? _domainOf(_Form form, String field, Map<String, Set<String>> csvUnion) {
    final q = form.byName[field];
    if (q == null) return null;
    final specials = {
      if ((q.dontKnow ?? '').isNotEmpty) q.dontKnow!,
      if ((q.refuse ?? '').isNotEmpty) q.refuse!,
    };
    final blank = q.optional;

    switch (q.type) {
      case QuestionType.radio:
      case QuestionType.combobox:
      case QuestionType.checkbox:
        final config = q.responseConfig;
        if (config == null) {
          return _Domain(
            regular: {
              for (final o in q.options)
                if (!specials.contains(o.value)) o.value,
            },
            specials: specials,
            blankAllowed: blank,
            isList: q.type == QuestionType.checkbox,
          );
        }
        if (config.source == ResponseSource.csv) {
          final union = csvUnion[field];
          if (union == null) return null;
          return _Domain(
            regular: {
              ...union,
              if (config.dontKnowValue != null) config.dontKnowValue!,
              if (config.notInListValue != null) config.notInListValue!,
            },
            specials: specials,
            blankAllowed: blank,
            isList: q.type == QuestionType.checkbox,
          );
        }
        return null;

      case QuestionType.text:
        final check = q.numericCheck;
        final min = check?.minValue;
        final max = check?.maxValue;
        if (check == null || min == null || max == null) {
          // Only the specials are known; enough for the ordering check, not
          // for coverage.
          return _Domain(
            regular: const {},
            specials: specials,
            blankAllowed: blank,
            isList: false,
            enumerable: false,
          );
        }
        final span = max - min;
        if (span > rangeCap || min != min.floor() || max != max.floor()) {
          return _Domain(
            regular: const {},
            specials: specials,
            blankAllowed: blank,
            isList: false,
            enumerable: false,
          );
        }
        return _Domain(
          regular: {
            for (var v = min.toInt(); v <= max.toInt(); v++) '$v',
            ...(check.otherValues ?? '')
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty),
          },
          specials: specials,
          blankAllowed: blank,
          isList: false,
        );

      case QuestionType.date:
      case QuestionType.datetime:
        return _Domain(
          regular: const {},
          specials: specials,
          blankAllowed: blank,
          isList: false,
          enumerable: false,
        );

      case QuestionType.information:
      case QuestionType.automatic:
        return null;
    }
  }

  static bool _fires(RuleRef r, String value) =>
      FieldComparator.compare(value, r.condition, r.response);

  static bool _isEquality(String op) {
    final o = op.trim();
    return o == '=' || o == '==' || o == 'contains';
  }

  // --------------------------------------------------------- skip_domain_gap

  /// Rules on one question that between them route the real answers but not
  /// the codes the tested question also accepts.
  ///
  /// `postskip: fever = 1 -> a`, `postskip: fever = 0 -> b` with Don't know
  /// enabled on `fever`: a `-7` matches neither, and the interview carries on
  /// to whatever comes next in sequence -- a route nobody designed. The `<>`
  /// idiom (`fever <> 1 -> b`) does not have this problem, because `-7 <> 1`
  /// is true, so a designer who used it gets no finding.
  List<Finding> _skipDomainGaps(_Form form, Map<String, Set<String>> csvUnion) {
    final findings = <Finding>[];
    for (final owner in form.topology.rulesOwnedBy.keys) {
      for (final isPre in const [true, false]) {
        // Equality tests only. A `<>` rule is true for the codes as well,
        // and an ordering rule that catches a negative code is the other
        // finding, `special_code_routed_as_value`.
        final cell = form.topology.rulesOwnedBy[owner]!
            .where((r) =>
                r.isPreskip == isPre &&
                !r.isDynamic &&
                r.jumpsForward &&
                _isEquality(r.condition))
            .toList();
        if (cell.isEmpty) continue;
        final byField = <String, List<RuleRef>>{};
        for (final r in cell) {
          (byField[r.field] ??= []).add(r);
        }
        for (final entry in byField.entries) {
          final domain = _domainOf(form, entry.key, csvUnion);
          if (domain == null || !domain.enumerable) continue;
          if (domain.specials.isEmpty && !domain.blankAllowed) continue;
          final rules = entry.value;

          final coveredRegular = domain.regular.where((v) => rules.any((r) => _fires(r, v))).toSet();
          if (coveredRegular.isEmpty) continue;
          final uncoveredSpecials = domain.specials.where((v) => !rules.any((r) => _fires(r, v))).toList();
          // A blank never fires anything; it is a gap only when the field can
          // legitimately be left blank.
          final blankGap = domain.blankAllowed;
          if (uncoveredSpecials.isEmpty && !blankGap) continue;

          final fullSplit = coveredRegular.length == domain.regular.length;
          final next = _fallThroughTarget(form, owner, isPre);
          final gaps = [
            ...uncoveredSpecials.map((v) => '$v (${_specialName(form, entry.key, v)})'),
            if (blankGap) 'a blank',
          ].join(', ');
          final ruleText = rules.map((r) => '${r.condition} ${r.response} -> ${r.target}').join('; ');
          findings.add(
            Finding(
              code: 'skip_domain_gap',
              table: form.table,
              field: '$owner.${isPre ? 'preskip' : 'postskip'}',
              detail: fullSplit
                  ? 'tests ${entry.key} with [$ruleText], which covers every '
                      'answer in its list but not $gaps -- so that answer falls '
                      'through to $next.'
                  : 'tests ${entry.key} with [$ruleText]. An answer of $gaps '
                      'matches no rule and falls through to $next, along with '
                      '${domain.regular.difference(coveredRegular).join(', ')}. '
                      'If the intent was "everyone except ${coveredRegular.join(', ')}", '
                      'a <> rule covers the codes too.',
            ),
          );
        }
      }
    }
    return findings;
  }

  /// Where the interview goes when no rule in the cell fires.
  String _fallThroughTarget(_Form form, String owner, bool isPre) {
    final order = form.topology.order;
    final start = (form.topology.indexOf[owner] ?? -1) + (isPre ? 0 : 1);
    for (var i = start; i < order.length; i++) {
      if (form.topology.displayable.contains(order[i])) {
        return isPre && i == start ? 'this question being asked' : order[i];
      }
    }
    return 'the end of the form';
  }

  String _specialName(_Form form, String field, String code) {
    final q = form.byName[field];
    if (q?.dontKnow == code) return "Don't know";
    if (q?.refuse == code) return 'Refuse';
    return 'special code';
  }

  // ---------------------------------------------- special_code_routed_as_value

  /// An ordering test that is true for a Don't-know or Refuse code, which are
  /// negative numbers: `age < 18` routes a -7 as a child.
  List<Finding> _specialRoutedAsValue(_Form form) {
    final findings = <Finding>[];
    const ordering = {'<', '<=', '>', '>=', '&lt;', '&gt;', '&lt;=', '&gt;='};
    for (final r in form.topology.rules) {
      if (r.isDynamic || !ordering.contains(r.condition.trim())) continue;
      final domain = _domainOf(form, r.field, const {});
      if (domain == null) continue;
      for (final code in domain.specials) {
        if (!_fires(r, code)) continue;
        findings.add(
          Finding(
            code: 'special_code_routed_as_value',
            table: form.table,
            field: r.nameIn(form.table),
            detail:
                '${r.field} ${r.condition} ${r.response} is true for $code '
                '(${_specialName(form, r.field, code)}), so that answer is '
                'routed to ${r.target} as if it were a number.',
          ),
        );
      }
    }
    return findings;
  }

  // ----------------------------------------------------- logic_check_malformed

  /// Each check evaluated once, alone, with every field answered. The engine
  /// turns a parse failure into a message beginning [malformedPrefix], which
  /// in the field is a Next button that never enables.
  List<Finding> _logicMalformed(_Form form) {
    final findings = <Finding>[];
    final synthetic = <String, dynamic>{
      for (final q in form.questions)
        q.fieldName: q.type == QuestionType.checkbox ? ['1'] : '1',
    };
    for (final q in form.questions) {
      for (var i = 0; i < q.logicChecks.length; i++) {
        final check = q.logicChecks[i];
        final probe = Question(
          type: q.type,
          fieldName: q.fieldName,
          fieldType: q.fieldType,
          logicChecks: [check],
        );
        final result = LogicService.evaluateLogicChecks(probe, synthetic);
        if (result != null && result.startsWith(malformedPrefix)) {
          findings.add(
            Finding(
              code: 'logic_check_malformed',
              table: form.table,
              field: '${q.fieldName}.logic[$i]',
              detail:
                  'the engine cannot read "${_oneLine(check.condition)}": '
                  '${result.substring(malformedPrefix.length).trim()}. In the '
                  'field this shows as an error and the Next button stays '
                  'disabled.',
            ),
          );
        }
      }
    }
    return findings;
  }

  static bool _isStaticList(Question q) =>
      (q.type == QuestionType.radio ||
          q.type == QuestionType.combobox ||
          q.type == QuestionType.checkbox) &&
      q.responseConfig == null &&
      q.options.isNotEmpty;

  // ------------------------------------------------------------- csv checks

  /// Loads and checks every csv-backed question, enumerating each cascade;
  /// returns field -> every value the list can show across parent answers.
  Future<Map<String, Set<String>>> _cascades(
    _Form form,
    CsvDataService csv,
    Directory surveyDir,
    Set<String> csvMissing,
    List<Finding> findings,
  ) async {
    final union = <String, Set<String>>{};
    for (final q in form.questions) {
      final config = q.responseConfig;
      if (config == null || config.source != ResponseSource.csv) continue;
      final file = config.file;
      if (file == null || csvMissing.contains(file)) continue;

      final rows = CsvDataService.parseCsv(
        File(p.join(surveyDir.path, file)).readAsStringSync(),
      );
      if (rows.isEmpty) {
        findings.add(
          Finding(
            code: 'csv_empty',
            table: form.table,
            field: q.fieldName,
            detail: '$file has a header and no rows, so the list is always empty.',
          ),
        );
        continue;
      }
      final header = rows.first.keys.toSet();
      final wanted = <String>{
        for (final f in config.filters) f.column,
        if (config.displayColumn != null) config.displayColumn!,
        if (config.valueColumn != null) config.valueColumn!,
      };
      // A missing column is SurveyGen's error (`_check_csv_columns_and_skip_values`),
      // so a package with one never gets built; here it only means the
      // cascade cannot be enumerated.
      if (wanted.any((c) => !header.contains(c))) continue;

      final parents = _placeholders(config);
      final valueColumn = config.valueColumn ?? config.displayColumn ?? '';
      final all = <String>{for (final r in rows) if ((r[valueColumn] ?? '').isNotEmpty) r[valueColumn]!};

      // Every combination of parent answers an interviewer could actually
      // arrive with. A csv-backed parent's values depend on *its* parents --
      // the districts of country 1 are not the districts of country 2 -- so
      // the combinations are built by walking the cascade from the top, each
      // level resolved through the same filter the app would apply, rather
      // than by crossing every parent's whole column with every other's.
      final combos = await _combinations(form, parents, csv, surveyDir);
      if (combos == null) {
        union[q.fieldName] = all;
        continue;
      }
      final total = combos.total;

      final seen = <String>{};
      final empty = <String>[];
      for (final combo in combos.rows) {
        List<QuestionOption> options;
        try {
          options = await csv.getResponseOptions(config, combo);
        } catch (_) {
          continue;
        }
        final real = options.where((o) =>
            o.value != config.dontKnowValue && o.value != config.notInListValue);
        if (real.isEmpty) {
          empty.add(combo.entries.map((e) => '${e.key}=${e.value}').join(', '));
        }
        seen.addAll(real.map((o) => o.value));
      }
      union[q.fieldName] = parents.isEmpty ? all : seen;

      if (empty.isNotEmpty) {
        final capped = total > combos.rows.length;
        findings.add(
          Finding(
            code: 'csv_cascade_empty',
            table: form.table,
            field: q.fieldName,
            detail:
                '$file gives an empty list for ${empty.length} of '
                '${combos.rows.length} parent answer combination(s)'
                '${capped ? ' (checked ${combos.rows.length} of $total)' : ''}: '
                '${empty.take(10).join('; ')}${empty.length > 10 ? '; …' : ''}. '
                'An interviewer arriving there has nothing to select.',
          ),
        );
      }
    }
    return union;
  }

  static Set<String> _placeholders(ResponseConfig config) => {
        for (final f in config.filters)
          for (final m in RegExp(r'\[\[(.+?)\]\]').allMatches(f.value))
            m.group(1)!,
      };

  /// Every combination of answers to [parents] an interviewer could hold,
  /// built top-down through the cascade. Null when some parent's values are
  /// unknown (free text, a database list, a field from another form).
  Future<_Combinations?> _combinations(
    _Form form,
    Set<String> parents,
    CsvDataService csv,
    Directory surveyDir,
  ) async {
    // The transitive parents, in form order, so each is resolved after the
    // ones it depends on.
    final closure = <String>{};
    void collect(String field) {
      if (!closure.add(field)) return;
      final config = form.byName[field]?.responseConfig;
      if (config != null) {
        for (final g in _placeholders(config)) {
          collect(g);
        }
      }
    }
    parents.forEach(collect);
    final ordered = closure.toList()
      ..sort((a, b) => (form.topology.indexOf[a] ?? 1 << 30)
          .compareTo(form.topology.indexOf[b] ?? 1 << 30));

    var rows = <Map<String, dynamic>>[{}];
    var total = 1;
    for (final field in ordered) {
      final q = form.byName[field];
      if (q == null) return null;
      final next = <Map<String, dynamic>>[];
      if (_isStaticList(q)) {
        final values = [
          for (final o in q.options)
            if (o.value != q.dontKnow && o.value != q.refuse) o.value,
        ];
        total *= values.length;
        for (final row in rows) {
          for (final v in values) {
            next.add({...row, field: v});
          }
        }
      } else if (q.responseConfig?.source == ResponseSource.csv) {
        final config = q.responseConfig!;
        var produced = 0;
        for (final row in rows) {
          List<QuestionOption> options;
          try {
            options = await csv.getResponseOptions(config, row);
          } catch (_) {
            return null;
          }
          for (final o in options) {
            if (o.value == config.dontKnowValue || o.value == config.notInListValue) {
              continue;
            }
            produced++;
            next.add({...row, field: o.value});
          }
        }
        total = produced == 0 ? total : produced;
      } else {
        return null;
      }
      rows = next.length > cascadeCap ? next.take(cascadeCap).toList() : next;
      if (rows.isEmpty) break;
    }
    // Only the fields the question itself filters on matter for the count;
    // the rest of the closure was scaffolding to reach them.
    final seen = <String>{};
    final trimmed = <Map<String, dynamic>>[];
    for (final row in rows) {
      final key = {for (final pName in parents) pName: row[pName]};
      final sig = key.entries.map((e) => '${e.key}=${e.value}').join('|');
      if (seen.add(sig)) trimmed.add(key);
    }
    return _Combinations(trimmed, total < trimmed.length ? trimmed.length : total);
  }

  // ------------------------------------------------------- skip_dropped_by_parser

  /// `SurveyLoader._parseSkips` silently drops a `<skip>` with no fieldname or
  /// no target. Count what the file says against what the engine kept.
  List<Finding> _droppedSkips(_Form form) {
    final xml = form.rawXml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    final declared = RegExp(r'<skip\b').allMatches(xml).length;
    final kept = form.topology.rules.length;
    if (declared <= kept) return const [];
    return [
      Finding(
        code: 'skip_dropped_by_parser',
        table: form.table,
        detail:
            'the XML declares $declared <skip> element(s) but the engine kept '
            '$kept. A skip with an empty fieldname or skiptofieldname is '
            'dropped without a message, so a rule the dictionary shows is '
            'not there in the field.',
      ),
    ];
  }

  static String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class _Form {
  _Form({
    required this.table,
    required this.questions,
    required this.topology,
    required this.rawXml,
    required this.linkingField,
  }) : byName = {for (final q in questions) q.fieldName: q};

  final String table;
  final List<Question> questions;
  final SkipTopology topology;
  final String rawXml;
  final String linkingField;
  final Map<String, Question> byName;
}

class _Combinations {
  const _Combinations(this.rows, this.total);
  final List<Map<String, dynamic>> rows;

  /// How many there would have been without the cap.
  final int total;
}

class _Domain {
  const _Domain({
    required this.regular,
    required this.specials,
    required this.blankAllowed,
    required this.isList,
    this.enumerable = true,
  });

  final Set<String> regular;
  final Set<String> specials;
  final bool blankAllowed;
  final bool isList;

  /// False when only [specials] are known.
  final bool enumerable;
}
