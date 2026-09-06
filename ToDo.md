## To Do

### Coverage

- **Nothing asserts that a valid `<calculation type="query">` still computes.** The engine
  runs one -- `sim/form_runner.dart`'s `_simulateDisplay` calls `AutoFields.compute` for
  every question carrying a `<calculation>`, so a query calculation really does hit
  `db.rawQuery` during a run -- but no fixture has one, so nothing would notice if it
  stopped returning a value. The gap predates the single-SELECT rule and was not created
  by it: `validateQuerySql` returns its input untouched and `auto_fields.dart` was not
  changed. It is worth closing here rather than in the app repo, because this is the only
  place the real save/lookup path runs outside a widget test.

  What it needs: a clean fixture -- a small CSV lookup file, which `DbService` imports as
  a table, and an automatic question whose `<calculation type="query">` selects from it
  with a `<parameter>` bound to an earlier answer -- and an assertion that the saved row
  carries the looked-up value, not an empty string. Note that `AutoFields` swallows a
  failed query and returns `''`, so the assertion has to be on the value; a run that
  merely completes proves nothing.

  A new fixture also needs its row in `test/fixtures/README.md` and its entry in
  `test/design/fixture_inventory_test.dart`, which holds every fixture to that table.
