# Lunote — Incremental Refactoring Plan

Companion to `docs/architecture-audit.md`. Findings there are referenced by
number (Issue #1–#6). Stages are ordered lowest-risk-first, per the audit
brief. **No stage has been executed** — this is the plan, pending approval.

Every stage assumes the working baseline is `./test/run.sh` after Stage 0's
fix (see below), run with `luajit` on `PATH` from the repo root.

---

## Stage 0 — Establish a clean baseline

**Objective**: Get the test suite to a state where a failure means something
broke, not that a developer's machine has a stray `.env` value. This is
prerequisite to trusting every later stage's "tests to run" step.

**Files/directories involved**: `test/support.lua`.

**Exact change**: `M.reset()` (or module setup) in `test/support.lua`
additionally stubs `lunote_env` so `Env.get` returns nil for
`LUNOTE_SYNC_URL` (and any other var) unless a test explicitly sets it,
instead of falling through to the real `.env`/process environment. The
existing `modules` table already has a pattern for this
(`modules["lunote_config"]`); add `modules["lunote_env"] = { get = function() return nil end }`
and, in `sync_spec.lua`, use `History.setState("endpoint", ...)` (which the
spec already does for the "local HTTP endpoint" case) as the only way tests
configure the endpoint. Confirm `Sync.endpoint()`'s default
(`https://lunote.xyz`) is what's asserted for the "production endpoint uses
TLS" case once `Env.get` no longer sees a real `.env`.

**Dependencies on earlier stages**: none — this is first.

**Expected behavior impact**: none in production. Test-only change.

**Tests to add or update**: no new test; this *fixes* the existing
`sync_spec.lua` assertion "production endpoint uses TLS" to pass
deterministically regardless of the developer's local `.env`.

**Commands to run**:
```sh
./test/run.sh
```
Expect: `0 failed` across all five specs.

**Risks**: very low. The only risk is masking a *real* future TLS
regression if the stub is wired wrong (e.g. stubbing `Env.get` to always
return a value instead of nil) — mitigated by asserting both the
"production defaults to https" case and the existing "local HTTP endpoint
stays supported" case still both pass after the change.

**Rollback strategy**: revert the one-line addition to `test/support.lua`
(and the corresponding one-line change in `sync_spec.lua` if any). No
production file touched, so rollback is test-file-only.

**Completion criteria**: `./test/run.sh` reports `0 failed` on a machine
with an arbitrary `LUNOTE_SYNC_URL` set in its environment or `.env`
(verify by re-running with `LUNOTE_SYNC_URL=http://example.test` exported
before invoking the script).

**Suggested commit boundary**: one commit — "test: stop sync_spec from
reading the developer's real .env".

---

## Stage 1 — Add missing tests around existing behavior

**Objective**: Close the two testing gaps identified in the audit that sit
on real (if low-probability) risk — cover extraction and the destructive
delete path in the history browser — *before* touching any production code
in later stages, so those stages have a regression net they don't have
today.

**Files/directories involved**: `test/` (new spec file(s) or additions to
existing ones); no production files.

**Exact changes**:
1. **Cover extraction** (`lunote_cover.lua`): add a `cover_spec.lua` (or
   fold into `history_spec.lua`, since cover state lives in the `book`
   table) that stubs `document:getCoverPageImage()` to return a fake
   blitbuffer-like object (width/height/`scale`/`writePNG`/`free`) and
   asserts: (a) no cover → `Cover.extract` returns nil without raising; (b)
   an oversized cover is scaled so neither dimension exceeds
   `MAX_DIMENSION`; (c) a `writePNG` failure returns nil and does not leave
   `TMP_PATH` behind. This requires extending `test/support.lua`'s module
   stub table with a minimal `document` double — check whether
   `test/support.lua` already has enough scaffolding (it currently fakes
   `getProps`/`file` on `ui.document` in `failures_spec.lua`'s local
   `makeUI()`; extend that pattern rather than inventing a new one).
2. **History browser delete path** (`lunote_history_browser.lua`): add
   assertions that `showConversations`' `hold_callback` → `ConfirmBox`'s
   `ok_callback` calls `History.deleteConversation(conversation.id)` with
   the correct id. `test/support.lua` already stubs `ui/widget/confirmbox`
   as a bare `Widget:extend{}`; extend the stub to capture the
   `ok_callback` closure so the test can invoke it directly, mirroring how
   `M.shown`/`M.ticks` already capture callbacks elsewhere in the file.

**Dependencies on earlier stages**: Stage 0 (a clean, trustworthy baseline
to add tests against).

**Expected behavior impact**: none — test-only.

**Tests to add or update**: as described above; net new assertions, no
existing assertions changed.

**Commands to run**:
```sh
./test/run.sh
```
Expect: all specs pass, assertion count higher than Stage 0's baseline.

**Risks**: low. The main risk is a stub that doesn't faithfully represent
the real KOReader API shape (e.g. `getCoverPageImage`'s real return type),
which would make the test pass without proving anything. Mitigate by
keeping the stub's shape minimal and directly modeled on what
`lunote_cover.lua` actually calls (`getWidth`, `getHeight`, `scale`,
`writePNG`, `free`) rather than a full blitbuffer reimplementation.

**Rollback strategy**: delete the new spec file / new assertions. No
production code affected.

**Completion criteria**: new assertions exist and pass; `test/run.sh`'s
total assertion count is visibly higher (currently 103 across the five
specs — see `test/run.sh`'s per-spec summaries).

**Suggested commit boundary**: two commits, one per gap closed — "test:
cover extraction (scaling, failure, no-cover)" and "test: history browser
delete calls History.deleteConversation".

---

## Stage 2 — Add a regression test for the cross-module note-marker invariant

**Objective**: CLAUDE.md invariant #2 (the AI-note marker must strip
cleanly) is enforced across two files (`lunote_annotations.lua` appends,
`lunote_history.lua` strips) via shared constants, but nothing currently
asserts that both sides *use* the shared constants rather than merely
happening to agree on the string value today. This closes that specific
gap called out in the audit's "Dependency and coupling concerns" section,
independent of Stage 1's gaps.

**Files/directories involved**: `test/history_spec.lua` or
`test/explain_spec.lua` (whichever already builds a full
annotate-then-mirror flow — check `explain_spec.lua` first, since it drives
`Annotations.saveToBook` for real).

**Exact change**: add an assertion, in a flow that calls
`Annotations.saveToBook` and then `History.mirrorAnnotations` (or the
higher-level flow that triggers both), that the mirrored `item.note` in
SQLite equals the user's original note text (or nil, for the no-prior-note
case) — i.e., that `History.stripAiNote` correctly strips what
`Annotations.saveToBook` actually appended, for **both** documented shapes
(appended after existing text, and standing alone). Check whether
`explain_spec.lua` already has one of the two shapes covered and add only
the missing one, rather than duplicating an existing assertion.

**Dependencies on earlier stages**: Stage 0.

**Expected behavior impact**: none — test-only.

**Tests to add or update**: as described.

**Commands to run**:
```sh
./test/run.sh
```

**Risks**: very low.

**Rollback strategy**: delete the added assertion(s).

**Completion criteria**: both note shapes (appended, standalone) have an
explicit assertion tracing append → mirror → stripped result.

**Suggested commit boundary**: one commit — "test: assert both AI-note
shapes strip cleanly through mirroring".

---

## Stage 3 — Fix stale documentation (Issue #4)

**Objective**: Correct the file-name table in `CLAUDE.md`/`AGENTS.md` (a
symlink to the same file) so it matches the actual repository, per the
audit's "differs from apparent intended architecture" finding.

**Files/directories involved**: `AGENTS.md` (edit this one directly —
`CLAUDE.md` is a symlink to it, so editing either file on disk without
respecting the symlink would break the link; edit `AGENTS.md`'s content).

**Exact change**: in the "How it fits together" table, replace the
`dialogs.lua` / `gpt_query.lua` / `annotations.lua` / `history.lua` /
`sync.lua` / `env.lua` rows' filenames with the actual
`lunote_dialogs.lua` / `lunote_query.lua` / `lunote_annotations.lua` /
`lunote_history.lua` / `lunote_sync.lua` / `lunote_env.lua`. No other
content in the table needs to change — the *descriptions* are accurate,
only the filenames are stale.

**Dependencies on earlier stages**: none — independent of Stages 0-2, but
sequenced early because it's zero-risk and immediately valuable (both to
human contributors and to future agent sessions reading this file, as this
very session did).

**Expected behavior impact**: none. Documentation only.

**Tests to add or update**: none applicable.

**Commands to run**: none required; optionally
`grep -n "^| \`" AGENTS.md` to visually confirm every listed filename now
exists (`ls lunote_dialogs.lua lunote_query.lua ...`).

**Risks**: none.

**Rollback strategy**: revert the one-file diff.

**Completion criteria**: every filename in the table matches a file that
exists in the repo root.

**Suggested commit boundary**: one commit — "docs: fix stale filenames in
the architecture table".

---

## Stage 4 — Move the pairing dialog into `lunote_dialogs.lua` (Issue #3)

**Objective**: Restore the module boundary the project's own documentation
states — "`dialogs.lua`: the Explain flow and the result viewer" — by
relocating the one dialog that currently lives outside it.

**Files/directories involved**: `main.lua`, `lunote_dialogs.lua`.

**Exact changes**:
1. In `lunote_dialogs.lua`, add a new exported function,
   e.g. `Dialogs.showPairingDialog(on_pair)`, containing the body currently
   at `main.lua:79-114` (the `InputDialog:new{...}` construction and its
   button callbacks), with the actual pairing call
   (`Sync.pair(code)` + `NetworkMgr:runWhenOnline` + the resulting
   `InfoMessage`) parameterized as a callback argument `on_pair` so
   `lunote_dialogs.lua` does not need to `require("lunote_sync")` itself —
   or, more simply given `lunote_dialogs.lua` already reaches into
   `History`/`Annotations` directly elsewhere, just `require("lunote_sync")`
   there too and keep the function self-contained, matching how every other
   dialog in that file already owns its full flow end-to-end. Prefer the
   simpler, self-contained version unless it creates a require cycle (it
   will not: `lunote_sync.lua` does not require `lunote_dialogs.lua`).
2. In `main.lua`, delete the inline `showPairingDialog` local function
   (lines 79-114) and change its one call site
   (inside `addToMainMenu`, currently `showPairingDialog()`) to
   `Dialogs.showPairingDialog()`.
3. `require("ui/widget/inputdialog")` in `main.lua` becomes unused once the
   function moves — remove that `require` line too, since
   `lunote_dialogs.lua` already requires it independently... **check first**:
   confirm nothing else in `main.lua` uses `InputDialog` before removing the
   require (a quick grep of `main.lua` for `InputDialog` after the move is
   the verification step, not an assumption).

**Dependencies on earlier stages**: Stage 0 (trustworthy baseline) and
ideally Stage 1/2 (more regression coverage before moving working code),
though this stage does not touch any of the newly-tested code paths
directly.

**Expected behavior impact**: **none** — this is a pure move, not a
behavior change. The dialog's title, description, button text, callback
logic, and the `NetworkMgr:runWhenOnline`/`InfoMessage` result handling are
unchanged, only relocated.

**Tests to add or update**: `explain_spec.lua` or a new assertion should
confirm the main menu's "Pair with web app" callback still opens a dialog
(via `M.shown`) after the move — if no such assertion exists today, this is
also new coverage for a previously-untested UI entry point, which the audit
did not separately flag but is a natural byproduct of this stage.

**Commands to run**:
```sh
./test/run.sh
grep -n "InputDialog" main.lua   # confirm no remaining use before removing the require
```

**Risks**: low-medium. The main risk is a subtle behavior change from
refactoring the closure (e.g. the `dialog` local used inside its own
button callbacks for `UIManager:close(dialog)`) — mitigate by moving the
code verbatim first (copy-paste, adjust only the `local function` →
`function Dialogs.showPairingDialog` signature and the module return
table), then only afterward consider any cleanup, so a diff review can
confirm byte-level equivalence of the moved logic.

**Rollback strategy**: revert the two-file diff; both changes are in the
same commit so a single `git revert` restores the prior state.

**Completion criteria**: "Pair with web app" / "Unpair from web app" menu
items behave identically (manually verified via `dev/lunote-sim`'s `menu`
→ `pick` commands per `dev/README.md`, since this is UI flow best checked
interactively); `main.lua` no longer defines `showPairingDialog`;
`lunote_dialogs.lua` exports it; all tests pass.

**Suggested commit boundary**: one commit — "refactor: move the pairing
dialog into lunote_dialogs.lua".

---

## Stage 5 — Extract the "load an optional Lua module" helper (Issue #1)

**Objective**: Replace the three near-identical `pcall(require(...))` +
print-on-missing blocks with one shared helper, reducing three places that
must agree on "how do we treat a missing optional config file" to one.

**Files/directories involved**: `lunote_env.lua` (the helper's new home —
it already owns "read optional external configuration," making it the
natural, existing-convention location rather than a new file per the task
brief's "do not create generic helper files" rule), `lunote_query.lua`,
`lunote_dialogs.lua`.

**Exact changes**:
1. In `lunote_env.lua`, add:
   ```lua
   --- Loads an optional module by name, returning nil (and logging once)
   --- if it is not present. Never raises.
   function Env.loadOptional(name)
     local ok, result = pcall(function() return require(name) end)
     if ok then return result end
     print(name .. ".lua not found, skipping...")
     return nil
   end
   ```
   (Match the exact existing print wording per call site — `lunote_query.lua`'s
   two messages and `lunote_dialogs.lua`'s message are already textually
   identical apart from the module name, so a single templated message is a
   faithful consolidation, not a behavior change.)
2. In `lunote_query.lua`, replace both the `api_key` and `lunote_config`
   loading blocks (lines 12-18, 20-26) with
   `local api_key_module = Env.loadOptional("api_key")` /
   `local CONFIGURATION = Env.loadOptional("lunote_config")`, adjusting the
   one place that reads `result.key` accordingly
   (`api_key = api_key_module and api_key_module.key`).
3. In `lunote_dialogs.lua`, replace lines 12-17 with
   `local CONFIGURATION = Env.loadOptional("lunote_config")`, and add
   `local Env = require("lunote_env")` to its requires (it does not
   currently require `lunote_env` — confirm this addition doesn't clash
   with anything already named `Env` in that file; it does not).

**Dependencies on earlier stages**: Stage 0 (baseline), Stage 4 (do this
after the pairing-dialog move, not before, so the two structural changes to
`lunote_dialogs.lua` don't land in the same diff and complicate review).

**Expected behavior impact**: none. Same `pcall`/`require`/print sequence,
now shared. The printed message text is preserved exactly (verify by
diffing the old vs. new message strings character-for-character before
committing).

**Tests to add or update**: existing tests already exercise both the
present and absent `lunote_config`/`api_key` cases indirectly (via
`modules["lunote_config"]` in `test/support.lua`); confirm they still pass
unmodified — if they do, no new test is strictly required, since this is
an internal refactor of already-tested behavior. Optionally add one direct
unit assertion on `Env.loadOptional` itself (present + absent cases) since
it is now a reusable, directly-callable function rather than inline logic.

**Commands to run**:
```sh
./test/run.sh
```

**Risks**: low. The main risk is the two call sites needing slightly
different treatment of the loaded result (`api_key_module.key` vs. the
whole `CONFIGURATION` table) — mitigate by keeping `Env.loadOptional`
returning the raw loaded value (no unwrapping) so each call site still owns
its own interpretation of what it loaded, exactly as today.

**Rollback strategy**: revert the three-file diff.

**Completion criteria**: `grep -rn "not found, skipping" *.lua` shows the
message coming from one place (`lunote_env.lua`) rather than three; all
tests pass; `lunote_query.lua`/`lunote_dialogs.lua` are shorter by the
duplicated lines.

**Suggested commit boundary**: one commit — "refactor: share the optional-
module-loading helper via lunote_env.Env.loadOptional".

---

## Stage 6 — Decide on the `api_key.lua` deprecation and the HTTP-duplication question (Issues #5, #6)

**Objective**: These two findings are explicitly **not** auto-applied by
this plan — they require a product/maintainer decision first (see the
audit's "Questions requiring human confirmation," reproduced in the final
response below). This stage exists as a placeholder so the decision, once
made, has a designated slot in the sequence rather than being bolted onto
an unrelated stage.

**Files/directories involved**: TBD based on the decision:
- If `api_key.lua` support is removed: `lunote_query.lua` (delete lines
  12-18 and the `api_key` fallback in `resolveSettings`), `README.md`
  (remove the "prior `api_key.lua` style configuration is deprecated" note,
  since there'd be nothing left to deprecate), `.gitignore` (the
  `/api_key.lua` entry can either stay harmlessly or be removed).
- If the HTTP-duplication (Issue #5) is worth unifying: a new
  `lunote_http.lua` with a single `post(url, body, headers)`-shaped
  function, called from both `lunote_query.lua` and `lunote_sync.lua`,
  **preserving each call site's distinct error-message shaping** (do not
  flatten the two APIs' genuinely different error-body formats into one).
  If the decision is *not* to unify (my assessment leans this way — see
  audit Issue #5), this stage is simply skipped for that half.

**Dependencies on earlier stages**: Stage 0 at minimum; practically, all
prior stages, since this is intentionally sequenced last as the only stage
touching behavior (removing a supported-but-deprecated config path is a
user-facing change, unlike every stage above).

**Expected behavior impact**: **Potentially user-facing** if `api_key.lua`
removal is chosen — any user still relying on that deprecated file (rather
than `.env`/`lunote_config.lua`) would lose their configured key with no
runtime warning beyond what the plugin already gives for "no API key
found." This is exactly the kind of change the task brief says not to make
without explicit identification — flagged here, not decided.

**Tests to add or update**: if `api_key.lua` is removed, delete or update
whatever test currently exercises that fallback (check
`test/explain_spec.lua`/`test/failures_spec.lua` for any `api_key`
references first — a quick grep before starting this stage is the
verification step). If `lunote_http.lua` is introduced, both
`lunote_query.lua`'s and `lunote_sync.lua`'s existing specs must continue
to pass unmodified (their behavior must not change, only its location).

**Commands to run**: `./test/run.sh` after either change.

**Risks**: **Medium** for the `api_key.lua` removal (real, if small,
user-facing breakage for anyone still on the old config style — likely a
shrinking population given the README has called it deprecated since
before this audit, but not verifiably zero). **Low-medium** for the HTTP
unification (mechanical, but touches the two most security/reliability-
sensitive files in the repo, so warrants the same care as Stage 4's
move-verbatim-first approach).

**Rollback strategy**: standard revert; no data migration involved either
way.

**Completion criteria**: whichever path is chosen is fully applied (no
half-removed `api_key.lua` support) and documented in `README.md` if
user-facing.

**Suggested commit boundary**: separate commits per decision — do not bundle
the `api_key.lua` removal and the HTTP unification into one commit, since
they are independent decisions with independent risk profiles.

---

## Summary table

| Stage | Risk | Behavior impact | Depends on |
| --- | --- | --- | --- |
| 0. Fix test isolation | Very low | None | — |
| 1. Add missing tests (cover, browser delete) | Low | None | 0 |
| 2. Add note-marker cross-module test | Very low | None | 0 |
| 3. Fix stale docs table | None | None | — |
| 4. Move pairing dialog into dialogs.lua | Low-medium | None (pure move) | 0, (1, 2 recommended) |
| 5. Share optional-module-load helper | Low | None | 0, 4 |
| 6. api_key.lua removal / HTTP unification | Medium / Low-medium | Potentially user-facing | 0–5, **needs a decision first** |

Stages 0-3 can proceed without further discussion. Stage 4-5 are
mechanical and low-risk but are still code changes to review individually.
Stage 6 is gated on the open questions listed in the final response and
should not be started without an explicit answer to those.
