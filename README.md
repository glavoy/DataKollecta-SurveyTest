# DataKollecta SurveyTest

A dry run for a survey package. Point it at the `.zip` SurveyGen built from your data dictionary
and it plays a few hundred simulated interviews through the **field app's own engine** -- the
same navigation, skip evaluation, logic checks and database code the app ships -- and tells you
what is wrong with the dictionary before anyone is in the field.

It is for **design mistakes**, and above all for **skip patterns that are wrong**: a question no
route can reach, a question asked of people it should not be, a Don't-know answer that falls
through a pair of rules that only thought about Yes and No. SurveyGen already checks the syntax
of every cell and the references between them; this tool checks what the form *does*.

## Running it

```bash
flutter run -d macos        # or -d windows / -d linux
```

Choose a package, press **Run**. The zip is only read, never changed. Everything the tool writes
goes under `<application support>/SurveyTest/`, never into a real GiSTX or DataKollecta
installation. A report is saved as a single HTML file after every run, and every finding that
came from one interview carries a **seed** that replays that interview exactly.

Runs are deterministic for a given seed, so a report can be reproduced and compared after a fix.

## How a run works

1. **Lint.** The package is read and checked without running anything, using the engine's own
   code: logic-check expressions parsed by the real parser, csv cascades resolved by the real
   csv service, `<skip>` elements the real loader drops, and how the rules on a question route
   the Don't-know / Refuse codes the field also accepts. Checks that need only the dictionary and
   the csv files -- unknown operators, literals that are not codes, csv columns, date ranges,
   mask lengths, fields redefined across forms -- are SurveyGen's, at generation time.
2. **Steered interviews.** For every skip rule, one interview tries to make it fire and one tries
   to keep it from firing, holding off every rule that could jump over the question on the way.
   For every question the other interviews never reached, one interview tries to get there. This
   is what makes "never fired" and "never reached" evidence rather than luck.
3. **Random interviews** with several strategies -- uniform, boundary values, skip-maximising,
   skip-avoiding, Don't-know-heavy -- with occasional backtracking.
4. **Report.** Coverage first, then findings grouped so one problem is one line no matter how
   many interviews hit it.

Each interview is a whole household: the base form, then every child form. Children the repeat
loop opens (`repeat_count_field` + `auto_start_repeat`) are run as many times as the parent
declared. Children an interviewer opens by hand -- a parent, a linking field, an
`entry_condition`, no repeat settings, like AVERT's `vaccination_status` -- are run **once for
every parent that meets the entry condition**, with the linking value (`barcode`, `hhid`)
arriving filled from the parent exactly as the selector screen fills it. The coverage section
says how many parents qualified and how many follow-ups were done.

## Reading the report

### Design problems -- the dictionary is wrong

Each of these is something to change in Excel and regenerate.

| Code | Meaning | What to look at |
|---|---|---|
| `cannot_advance` | No answer gets past this question: a range no value satisfies, a logic check that always fires, a list with nothing to select. The app's Next button is dead here. | The question's own LowerRange/UpperRange, LogicCheck, Responses |
| `question_never_reached` | No interview -- not even one steered straight at it -- displayed this question. The detail names the skips that closed every route. | The named rules; usually two that between them cover every value |
| `form_never_entered` | No interview opened this form: no parent met its `entry_condition`, or the repeat loop never started. | The parent's `entry_condition` and `repeat_count_field`, or the count question's skips |
| `information_screen_fell_through` | An information screen with postskips is a terminal screen ("not eligible, stop"). An interview reached it, no postskip fired, and it carried on into the questions after. The detail shows the answers that did it. | The postskips: they must cover every answer that can reach the screen |
| `skip_domain_gap` | Rules on one question route the real answers but not Don't know / Refuse / blank. `fever = 1 -> a`, `fever = 0 -> b` sends a -7 nowhere. `prevdiag = 0 -> skip` asks a Don't-know respondent when they were diagnosed. | Add a rule for the codes, or use `<>` (true for the codes too) |
| `special_code_routed_as_value` | An ordering test is true for a negative code: `age < 18` routes -7 as a child. | Guard with `= -7` first, or use a different operator |
| `skip_dropped_by_parser` | The XML has a `<skip>` the engine dropped (no fieldname or target). | Regenerate; if it persists, the dictionary row is malformed in a way SurveyGen let through |
| `logic_check_malformed` | The engine's own parser cannot read this LogicCheck. In the field it shows an error and the Next button stays disabled. | The expression |
| `logic_check_inert` | Every time this check ran, a field it names was blank -- skipped by a named rule on every route to the check. A blank operand passes, so the check never fires. | Whether the check belongs on a route the skips no longer allow |
| `csv_file_missing` / `csv_empty` | The csv a list reads is absent from the package, or has no rows. | The `source:` block and the csv |
| `csv_cascade_empty` | Some combination of parent answers filters the csv to nothing; an interviewer arriving there has an empty list. Built by walking the cascade top-down, so only real combinations are counted. | The csv rows for the named parents |
| `unanswerable` | At run time a list came back empty **regardless of earlier answers** -- its filters name no other field. A list that is empty *because of* an earlier answer (PRISM's "who slept under this net" once every member is named) is not a defect: the interviewer goes back and changes the earlier answer, the runner does the same, and the question appears under *Routes that had to go back* instead. | The `source:` block |
| `skip_rule_always_fired` / `skip_rule_never_fired` / `skip_rule_never_evaluated` | Coverage. A rule only exercised one way was not tested as a branch. When a steered interview also failed, the detail says what it tried; when no answer could possibly satisfy it, the detail names the two rules that contradict -- typically the same rule written on an earlier question, which makes this one dead. A postskip on an **information screen** that always fires is *not* reported: the screen is shown only on the branch its preskips leave open, and the postskip carrying that branch on is the design. It still counts in the coverage numbers. | Whether the rule is redundant or the condition is wrong |

### Information screens

An `information` question displays text and stores nothing. The report treats it accordingly:
it is never "reached but never answered"; a postskip on it that fires every time is not a
finding; and a postskip on it that *fails* to fire is `information_screen_fell_through`, since
a terminal screen the interview continues past is the one thing such a screen must not do.

### Skip decisions

Per form, three tables to read against the paper questionnaire:

- **A. After this answer, the next question shown was** -- for every field a skip rule tests,
  each answer seen and where it led, with counts. This is the table that finds "96 goes to the
  wrong place" and "95 and 96 are both in the list but only 96 is routed".
- **B. Under which answers each gated question was shown or skipped** -- the inverse. The
  answer columns are context; the *rule* column is what the engine reported firing, and is the
  cause.
- **C. Questions with postskips and how often none fired** -- falling through is normal for an
  ordinary question and a defect for an information screen.

### Steered interviews

How many of the steering plans achieved their goal, and for the ones that did not, what values
they tried and what happened. A plan that could not even be built ("no answer can satisfy this")
is the interesting kind: two rules contradict.

### Engine-integrity problems -- the app, not the dictionary

Collapsed by default. `answer_changed`, `record_missing`, `duplicate_primary_key`,
`degraded_key`, `stoptime_before_starttime`, `missing_starttime`, `repeat_livelock`,
`save_failed`, `value_never_asked`, `child_link_missing` (a child saved without its parent's
linking value). Nothing in a dictionary causes these; they mean the field
app did something wrong with a valid package, and they exist here because this is the only place
the real save and repeat path runs outside a widget. Switch them off with the engine-checks
setting if you only want the design view.

## What it cannot see

- **When a follow-up is done.** A manually-entered child is done for every parent that
  qualifies, once. In the field the interviewer decides when; the harness cannot model a
  follow-up that is skipped or repeated by choice.
- **Computed fields.** A rule that tests an `automatic` or calculated field cannot be steered
  directly; the interviews steer the fields it is computed from where they can, and the report
  says "computed, not steerable".
- **Verification fields.** A steered value that a logic check refuses (`age` must match `dob`) is
  replaced by an answer that passes, and the report says which value was refused.
- **Intent.** The decision tables show what the form does. Whether that is what the questionnaire
  meant is for the designer reading them.

## For developers

```bash
flutter analyze && flutter test
```

The suite runs entirely on the fixtures under `test/fixtures/` (see its README): one package per
defect class, each tripping exactly one finding, plus `household_repeat` for the engine
self-tests under `test/engine/`. Design-finding tests live under `test/design/`.

This repo compiles `package:datakollecta` from `../DataKollecta` by path. An app refactor can
break it without failing the app's own tests; run this suite as part of any app-service change.
The doc comments on `installer.dart`, `sandbox.dart`, `sim/form_runner.dart` and
`sim/virtual_respondent.dart` explain the decisions that are not obvious from the code.
