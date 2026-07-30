# Developing without a Kindle

Copying the plugin to a device and poking at it through an e-ink screen is a
terrible edit-test loop. This directory gives you two faster ones.

| | Use it for | Speed |
| --- | --- | --- |
| **`./dev/askgpt-sim`** | Everything except pixels: the flows, the database, the annotation writes, the sync protocol | Instant |
| **KOReader desktop emulator** | How it actually looks and feels; whether `saveHighlight` finds positions in your document format | Slow, but still far quicker than a device |

## The simulator

```sh
apt-get install lua5.1 lua-sql-sqlite3 lua-cjson lua-socket lua-sec
./dev/askgpt-sim
```

```
askgpt> open
opened "Critique of Pure Reason" by Immanuel Kant  (0 annotation(s), md5 d98e6c84)
askgpt> select Act only according to that maxim whereby you can at the same time
askgpt> explain
pressing “Explain”
  » Asking ChatGPT…
┌──────────────────────────────────────────────────────────────┐
│ Explanation                                                  │
├──────────────────────────────────────────────────────────────┤
│ Highlighted text: "Act only according to that maxim…"        │
│                                                              │
│ [the explanation]                                            │
└──────────────────────────────────────────────────────────────┘
askgpt> notes
   1. [Chapter 1 p.10] Act only according to that maxim…
      | — AskGPT —
      | [the explanation]
askgpt> sync
```

`help` lists every command. The useful ones beyond the obvious:

- **`explain <n>`** — runs Explain against an *existing* annotation instead of a
  fresh selection, which is the path that appends to a note you already wrote.
- **`sql <query>`** — raw SQL against the store. This is the debugger part; it is
  how you check what would actually be synced.
- **`menu`** then **`pick <n>`** — drives the plugin's main menu the way KOReader
  would, including the file-manager case where no book is open.
- **`mock off`** — stop faking the model and make real API calls.

### What is real and what is not

Real: the plugin's own modules, loaded unmodified. Real SQLite. Real HTTP for
sync. Real annotation persistence — highlights and notes are written to
`dev/data/sidecar/`, standing in for KOReader's `.sdr` directories, so they
survive between runs and mirroring is worth exercising.

Faked: KOReader's widget layer, though the stubs are faithful enough that the
widgets still get *constructed* — a mistake in `ChatGPTViewer:init()` surfaces
here rather than on the device. And the model, by default (see below).

Not covered: how anything looks, e-ink refresh behaviour, and whether
`ui.highlight:saveHighlight()` returns a usable index for your document format.
Scanned PDFs in particular can hand back a selection with no positions. Use the
emulator for those.

### The mock model

Completion requests are intercepted by default and answered with obviously
labelled placeholder text, so the simulator works with no API key, no network
and no spend. Sync traffic is never intercepted.

`mock off` in the console, or `ASKGPT_SIM_MOCK=0`, sends the real thing using
whatever `.env` you have configured.

### Testing sync without deploying anything

```sh
node dev/stub-server.mjs                                  # terminal one
ASKGPT_SYNC_URL=http://127.0.0.1:4000 ./dev/askgpt-sim    # terminal two
```

The stub accepts any pairing code, prints every payload it receives, and keys
records by `uuid` the way the real server does — so you can watch a re-sent batch
correctly do nothing. `GET http://127.0.0.1:4000/` dumps what it holds.

To go against the real thing instead, run the web app locally and point
`ASKGPT_SYNC_URL` at `http://127.0.0.1:3000`.

### Scripts

Non-interactive runs, good for a quick regression check by eye:

```sh
./dev/askgpt-sim dev/scripts/smoke.txt
./dev/askgpt-sim dev/scripts/sync.txt
```

## The KOReader desktop emulator

For anything visual. KOReader builds and runs on Linux and macOS:

```sh
git clone https://github.com/koreader/koreader
cd koreader && ./kodev build && ./kodev run
```

Then link this checkout into it, so edits need no copying:

```sh
./dev/install-to-koreader.sh ../koreader/koreader-emulator-x86_64-linux-gnu/koreader
```

The path is whatever directory contains `plugins/` — for a source build that is
under `koreader-emulator-*`; for an AppImage, extract it with
`--appimage-extract` and use `squashfs-root/usr/lib/koreader`.

`crash.log` in that directory records every plugin directory scanned and every
plugin that failed to load, which is the first place to look when the **Explain**
button does not appear.

> I have not run the emulator myself — this container has no display — so treat
> the build commands as KOReader's documented ones rather than something
> verified here. The simulator above *is* verified.

## Automated tests

The simulator is for poking at things by hand. For assertions, `../test/run.sh`
runs 103 of them against real SQLite. Both matter: the test suite caught the
book-reference bug, and the simulator caught a note-marker bug the suite missed.
