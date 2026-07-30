# Context for agents

## What this is

A KOReader plugin for e-readers (Kindle, Kobo). You highlight a passage in a
book, tap **Explain**, and get it explained in plain language with the
background needed to follow it. Explanations are saved per book and can be
synced to a companion web app.

Two repositories:

- **this one** — the plugin. Lua 5.1, runs on LuaJIT inside KOReader.
- **[koreader-ai-plugin-webapp](https://github.com/memit0/koreader-ai-plugin-webapp)** —
  Next.js + Supabase. Lists your books; each book shows its highlights, your
  notes and the AI explanations together.

## How it fits together

```
highlight → Explain → OpenRouter (default: google/gemini-2.5-flash-lite)
                         ↓
        ┌────────────────┴────────────────┐
        ↓                                 ↓
KOReader annotation              lunote_history.sqlite3
(the book's own note)            (transcripts + sync outbox)
        ↓                                 ↓
  Bookmarks, Exporter              "Sync to web app" → Supabase
```

The explanation is written **into the book's own annotation**, so it appears in
KOReader's Bookmarks beside your highlights and your own notes. SQLite alongside
holds full transcripts (including follow-up questions) and the sync outbox.

| File | Role |
| --- | --- |
| `main.lua` | Plugin entry: highlight button, main menu, mirror-on-close |
| `dialogs.lua` | The Explain flow and the result viewer |
| `gpt_query.lua` | Provider resolution and the API call |
| `annotations.lua` | Writes the explanation into the book's annotation |
| `history.lua` | SQLite store, annotation mirror, outbox queries |
| `sync.lua` | Batched, resumable push to the web app |
| `env.lua` | Reads `.env` (KOReader has no dotenv) |

## Invariants — breaking these causes real damage

1. **Nothing in the query or sync path may raise.** KOReader runs scheduled
   tasks unprotected, so an uncaught error terminates the reader mid-read. Return
   `nil, message` and surface it in an InfoMessage. This has already been the
   cause of one crash-on-every-API-error bug.
2. **The AI note marker must strip cleanly.** `history.lua` appends the
   explanation to an annotation's note behind `— Lunote —`. Mirroring strips from
   that marker so the web app receives *your* note, not the generated text. Two
   shapes exist — appended after a note you wrote, and standing alone on a
   highlight that had none — and both must strip, or explanations sync as if you
   authored them.
3. **Record uuids are stable** (`device:table:rowid`). The server upserts on
   them, which is what makes a re-sent batch after dropped wifi a no-op rather
   than a duplicate. Never regenerate them.
4. **Sync stays keyset-paginated in batches of 25**, marking rows synced only
   after the server acknowledges. A Kindle has little RAM and worse wifi.
5. **Annotations mirror on document close**, which is what lets sync read only
   SQLite and never walk sidecars. Do not make sync touch the filesystem.
6. **Target Lua 5.1 / LuaJIT.** Lua 5.1 silently accepts invalid escape
   sequences; LuaJIT rejects them, and the device runs LuaJIT. Check any new file
   loads under `luajit`.
7. **The plugin directory must be named `lunote.koplugin`** — KOReader ignores
   anything else, silently.

## Testing — do not require a device

```sh
./test/run.sh        # 103 assertions against real SQLite
./dev/lunote-sim     # interactive simulator: real plugin code, mocked model
```

The simulator runs the plugin's real modules with KOReader's widget layer
stubbed. `dev/stub-server.mjs` stands in for the sync endpoint. Between them the
whole flow works with no API key, no device and nothing deployed. See
`dev/README.md`.

Only two things genuinely need hardware: how it looks on e-ink, and whether
`saveHighlight()` returns a usable index for a given document format (scanned
PDFs can yield a selection with no positions).

## Configuration

`OPENROUTER_API_KEY` in a `.env` beside the plugin. `lunote_config.lua`
optionally overrides model, provider, endpoint and the `features` table
(`explain_prompt`, `translate_to`, `save_to_notes`, `log_translations`).
Precedence is uniform: `lunote_config.lua` > `.env` > defaults.

## State of things

Explain, local history, the browser, pairing and sync all work and are covered
by tests. The web app renders the merged view and its sync endpoint is verified
against payloads captured from the real plugin. Not yet verified on a physical
device.
