# Test fixtures

Each directory is one survey package in loose parts -- form XML, `survey_manifest.gistx`, any
small CSV -- zipped at test time by `buildFixtureZip`. Real dictionaries belong to studies and
are gitignored; these are small and deliberately wrong in exactly one way each, so that a test
can assert "this code, and nothing else". `test/design/fixture_inventory_test.dart` holds every
fixture to the row below.

| Fixture | Trips | What is wrong |
|---|---|---|
| `malaria_screening` | `question_never_reached`, `skip_rule_*` | two skips on `sex` between them close the route to four questions (the case coverage exists for) |
| `trap_logic` | `cannot_advance` | a logic check no value can satisfy |
| `deep_gate` | none (clean) | a question behind three independent gates; reachable only by steering |
| `info_fallthrough` | `information_screen_fell_through`, `skip_domain_gap` | a terminal screen whose postskip does not cover Don't know |
| `dk_fallthrough` | `skip_domain_gap` | Yes and No routed, Don't know forgotten |
| `special_as_number` | `special_code_routed_as_value` | `age < 18` is true for -7 |
| `logic_malformed` | `logic_check_malformed` | `age 18`, an expression the engine's parser rejects |
| `logic_inert` | `logic_check_inert` | a check whose operand every route has skipped |
| `csv_cascade_empty` | `csv_cascade_empty` | a parent option with no rows in the csv |
| `skip_dropped` | `skip_dropped_by_parser` | a `<skip>` with no fieldname |
| `household_repeat` | none (clean) | a parent with a generated id, a repeating child, and a follow-up entered by hand when `enrolled=1`; the engine self-tests run on it |
