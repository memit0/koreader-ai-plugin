# Lunote — Proposed Structure

## Proposed directory tree

The recommendation is: **keep the current flat layout.** The tree below is
the *current* structure annotated with what stays, what moves, and why —
not a new tree to migrate to. There is no directory reorganization in this
plan; every change in `docs/refactoring-plan.md` happens inside existing
files or moves one function between two existing files.

```
koreader-ai-plugin/
├── _meta.lua                      # KOReader plugin manifest — stays
├── main.lua                       # entry point — stays; loses showPairingDialog (Stage 4)
├── lunote_dialogs.lua             # Explain/Translate flows + viewer wiring — stays; gains showPairingDialog (Stage 4)
├── lunote_query.lua               # provider resolution + API call — stays
├── lunote_annotations.lua         # book-identity + note-writing — stays
├── lunote_history.lua             # SQLite store, schema, outbox — stays
├── lunote_history_browser.lua     # browse/delete UI over History — stays
├── lunote_sync.lua                # batched push to the web app — stays
├── lunote_env.lua                 # .env reader — stays; gains Env.loadOptional (Stage 5)
├── lunote_cover.lua               # cover PNG extraction — stays
├── lunote_viewer.lua              # generic scrollable-text widget — stays
├── lunote_update_checker.lua      # GitHub release check — stays
├── README.md, LICENSE, .env.sample, lunote_config.lua.sample, .gitignore
├── .github/workflows/release.yml  # CI: test → zip → release
├── AGENTS.md (CLAUDE.md → symlink) # gets its file-name table corrected (Stage 3)
├── docs/                          # NEW: this audit and plan
│   ├── architecture-audit.md
│   ├── refactoring-plan.md
│   └── proposed-structure.md
├── test/
│   ├── run.sh                     # entry point
│   ├── support.lua                # shared KOReader stubs; gains a lunote_env stub (Stage 0)
│   ├── sq3shim.lua                # SQLite shim for the test backend
│   ├── history_spec.lua
│   ├── sync_spec.lua
│   ├── explain_spec.lua           # gains a pairing-dialog assertion (Stage 4)
│   ├── failures_spec.lua
│   ├── update_spec.lua
│   ├── cover_spec.lua             # NEW (Stage 1)
│   └── dump_payload.lua           # standalone debug script, not part of run.sh
└── dev/
    ├── lunote-sim, run.lua, kosim.lua, json.lua, stub-server.mjs
    ├── install-to-koreader.sh
    ├── README.md
    ├── data/                      # simulator's persisted state (sidecar, sqlite, sample book)
    └── scripts/                   # non-interactive smoke/sync scripts
```

**Not part of this tree, and not touched by this plan**: `.agents/` and
`skills-lock.json` at the repo root. As noted in the audit, these are an
unrelated Clerk skills bundle that appears to have landed in this directory
by accident (untracked, no relation to the KOReader plugin). They are
flagged for the user's attention, not moved or deleted as part of this
plan — that decision belongs to the user, not to a refactor.

## Responsibility of each major directory

- **`/` (repo root)**: the plugin as KOReader loads it. Every `.lua` file
  here is copied verbatim into the release zip's `lunote.koplugin/`
  directory (per `.github/workflows/release.yml`) and must remain
  loadable via KOReader's flat `require()` resolution — this is *why* the
  layout is flat and prefixed (`lunote_*`) rather than nested: KOReader
  plugins are a directory of top-level modules, and nesting would only
  buy `require("subdir/lunote_x")` friction with no corresponding benefit,
  since there is no name-collision risk to solve (the `lunote_` prefix
  already exists for that, and predates this audit).
- **`docs/`**: architecture/planning documents for maintainers and future
  agent sessions. New in this plan; holds only the three deliverables
  above, nothing else.
- **`test/`**: automated, assertion-based specs plus the shared stub
  environment (`support.lua`) and SQLite shim (`sq3shim.lua`) they depend
  on. Everything here is meant to run headless in CI
  (`.github/workflows/release.yml` installs `luajit`/`lua-sql-sqlite3` and
  runs exactly `./test/run.sh`).
- **`dev/`**: interactive/manual tooling for a human iterating locally —
  not run in CI, not part of the release artifact. Its stub environment
  (inside `kosim.lua`) is deliberately separate from `test/support.lua`'s
  (see audit "Probable issues") because the two optimize for different
  things (console rendering + persisted state vs. fast silent assertions).

## Dependency rules

These are the rules the codebase **already follows** — stated explicitly so
future changes can be checked against them, not new rules to impose:

1. **Direction**: UI/orchestration (`main.lua`, `lunote_dialogs.lua`,
   `lunote_history_browser.lua`) may depend on domain logic
   (`lunote_annotations.lua`, `lunote_query.lua`, `lunote_sync.lua`), which
   may depend on storage/infra (`lunote_history.lua`, `lunote_cover.lua`,
   `lunote_env.lua`). Nothing below may `require` anything above it. No
   exception exists today (verified by reading every `require` in every
   file); no exception should be introduced.
2. **Single owner of the datastore**: only `lunote_history.lua` opens a
   SQLite connection (`SQ3.open`) or references `DB_PATH`. Every other
   module reaches persistent state through `History.*` functions. This
   rule should extend to any new persistent state introduced later — do
   not open a second `SQ3.open` call anywhere else, and do not add a
   second on-disk store for something that could be a new table or a
   `sync_state` key.
3. **`lunote_viewer.lua` stays a leaf.** It knows how to display scrollable
   text and take a question callback; it must not gain a `require` on
   `lunote_history.lua`, `lunote_annotations.lua`, or `lunote_query.lua`.
   Both current callers (`lunote_dialogs.lua`, `lunote_history_browser.lua`)
   already respect this — keep it that way so the widget stays reusable
   and stays testable in isolation from the domain logic.
4. **Errors cross module boundaries as `nil, message`, never as a raised
   error**, at every I/O boundary (`lunote_query.lua`, `lunote_sync.lua`,
   `lunote_history.lua`'s `withConn`). This is CLAUDE.md invariant #1 and
   is the one rule in this document that is a hard behavioral requirement,
   not a style preference — any new I/O call (a new API integration, a new
   query) must follow it and should get a `failures_spec.lua`-style test
   proving it does.
5. **Optional external configuration is read once, through one path.**
   After Stage 5, that path is `Env.loadOptional` in `lunote_env.lua`,
   `Env.get` for `.env`/environment values in the same file, with the
   documented precedence (`lunote_config.lua` > `.env` > default)
   implemented by each caller that needs it (`lunote_query.lua` for
   provider settings, `lunote_dialogs.lua` for feature flags) — the
   precedence *policy* is shared knowledge (documented in CLAUDE.md), the
   precedence *implementation* is intentionally local to each caller since
   provider settings and feature flags have different fallback sources
   (provider settings fall back to `.env`; features do not, because there
   is no `.env` equivalent for a prompt string or a translation target
   language).

## Where representative existing files would move

**Nowhere** — this plan moves exactly one function
(`showPairingDialog`, `main.lua` → `lunote_dialogs.lua`, Stage 4) and
otherwise adds one new file (`test/cover_spec.lua`, Stage 1) and one new
directory (`docs/`, this deliverable). No existing file changes location.

The one function move, worked through as an example of "how imports change
when something moves":

- **Before**: `main.lua` requires `ui/widget/inputdialog` directly (for
  `InputDialog:new{...}` inside `showPairingDialog`) alongside its other
  requires (`Dialogs`, `Annotations`, `History`, `HistoryBrowser`, `Sync`,
  `UpdateChecker`). `lunote_dialogs.lua` does not know pairing exists.
- **After**: `lunote_dialogs.lua` requires `ui/widget/inputdialog` (it
  already requires `ui/uimanager` and `ui/widget/infomessage` for its
  existing dialogs, so this is one more line in a file that already owns
  this category of import) and `lunote_sync.lua` (for `Sync.pair`/`Sync.unpair`,
  which `main.lua` already requires today and would no longer need to, since
  its only remaining use of `Sync` — the `isConfigured()`/`unpair()` calls in
  `addToMainMenu` — stays where it is, so `main.lua`'s `require("lunote_sync")`
  is **not** removed, only `showPairingDialog`'s internal use of it moves).
  `main.lua` drops `require("ui/widget/inputdialog")` (verified unused
  elsewhere first, per Stage 4's exact instructions) and gains one call:
  `Dialogs.showPairingDialog()` in place of the old inline `showPairingDialog()`.

## Files that should remain where they are

Every file not named above — which is nearly all of them. Specifically
called out because each was a plausible "could this move/split" candidate
during this audit, and the answer for each is no:

- **`lunote_history.lua` stays one file** despite being the largest
  (595 lines) and covering four sub-concerns (schema/migration,
  conversation CRUD, annotation mirroring, outbox queries). Splitting it
  would separate code that all shares one schema, one `withConn` helper,
  and one set of "never raise, keyset-paginate" conventions — the current
  single file makes those shared conventions visible in one read, which a
  split into `lunote_history_schema.lua` / `lunote_history_outbox.lua` /
  etc. would obscure for a project this size. Revisit only if the outbox
  queries grow substantially (e.g. a second sync target, a pull path) to
  the point they dominate the file's line count.
- **`lunote_viewer.lua` stays a single file and stays a close adaptation
  of KOReader's `TextViewer`**, not refactored toward the plugin's own
  idioms. It is boilerplate widget-composition code by nature (button
  tables, gesture forwarding, movable-container wiring); rewriting it to
  look more like the rest of the plugin would increase the risk of
  breaking gesture handling for no maintainability gain, since its
  complexity is inherent to the KOReader widget system, not to this
  project's own design choices.
- **`dev/kosim.lua` stays separate from `test/support.lua`**, per the
  audit's "Probable issues" — different purposes (interactive console
  rendering + persisted state vs. fast silent assertions) justify the
  duplication of stub scaffolding; merging them would couple two things
  that intentionally evolve at different paces (the test stubs need to
  stay minimal for speed; the sim stubs need to stay faithful for
  demonstration value).
- **`_meta.lua` stays a 7-line manifest.** No responsibility to extract;
  it is already minimal.
- **The `lunote_` filename prefix stays on every plugin file.** It is not
  redundant with a directory (there is no `lunote/` subdirectory to make it
  so) — it is what keeps this plugin's modules from colliding with
  KOReader's own module namespace or another plugin's, given KOReader's
  flat, shared `package.path` across all loaded plugins.

## Areas where no reorganization is justified

- **No `src/`/`lib/` split.** Nothing in the current root is not "the
  plugin" — there is no generated output, no build artifact, no second
  language's source tree to separate it from. A `src/` directory would
  exist purely as ceremony.
- **No per-feature subdirectories** (e.g. `explain/`, `sync/`, `history/`
  each with their own files). The current one-file-per-concern layout
  already gives each concern a distinct, greppable name; wrapping each in
  its own directory would multiply `require()` path segments across every
  file for a project with twelve source files total, none of which are
  large enough to need internal subdivision.
- **No extraction of a generic `lunote_http.lua`** unless Stage 6 (in
  `docs/refactoring-plan.md`) is explicitly decided in favor of it. The
  task brief's instruction not to create generic helpers "unless there is
  a clearly defined shared responsibility" applies directly here — the two
  HTTP call sites (`lunote_query.lua`, `lunote_sync.lua`) share a shape but
  not their error semantics, and forcing a shared abstraction before
  confirming that's wanted risks exactly the kind of premature abstraction
  the audit was asked to avoid.
- **No provider plugin system for `lunote_query.lua`'s `PROVIDERS` table.**
  Two entries (`openrouter`, `openai`) plus an escape hatch
  (`base_url`/`additional_parameters` for anything OpenAI-compatible,
  which is how the README documents pointing the plugin at Ollama) is
  already the minimum viable design for "one dialect, a couple of known
  hosts, and an override for everything else." A registry/factory pattern
  here would be solving a scale problem this project does not have.
