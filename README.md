# Lunote: ChatGPT Highlight Plugin for KOReader

Introducing Lunote, a new plugin for KOReader that explains the parts of the book you're reading using ChatGPT, an AI language model. Highlight a passage, tap **Explain**, and you get the passage in plain language along with the background you need to follow it — no question to type. With Lunote, you can have a more interactive and engaging reading experience, and gain a deeper understanding of the content.

## Getting Started

To use this plugin, You'll need to do a few things:

Get [KoReader](https://github.com/koreader/koreader) installed on your e-reader. You can find instructions for doing this for a variety of devices [here](https://www.mobileread.com/forums/forumdisplay.php?f=276).

If you want to do this on a Kindle, you are going to have to jailbreak it. I recommend following [this guide](https://www.mobileread.com/forums/showthread.php?t=320564) to jailbreak your Kindle.

Then set up explanations, either way round.

### Either: pair with the web app

Subscribe at [lunote.xyz](https://lunote.xyz), then **Menu → Lunote → Pair with web app** and type the six characters the site shows you. That is the whole setup — explanations are generated for you, so there is no API key to obtain and no file to edit on the device. Your allowance is capped, so it cannot run up a bill.

### Or: bring your own API key

Get an [OpenRouter API key](https://openrouter.ai/keys) and put it in a `.env` file inside the `lunote.koplugin` directory — copy `.env.sample` and fill in your key:

```sh
OPENROUTER_API_KEY=sk-or-v1-...
```

That is the whole setup. The plugin defaults to `google/gemini-2.5-flash-lite`, which is cheap, fast and more than capable enough for explaining a paragraph of prose. To use a different one, pick any id from [openrouter.ai/models](https://openrouter.ai/models) and add:

```sh
OPENROUTER_MODEL=google/gemini-2.5-flash
```

> **Note:** `.env` is gitignored, so your key stays out of version control. Edits to it are picked up when KOReader restarts.

A key you configure yourself always wins. If you have both a subscription and your own key, the plugin keeps using yours, so a working setup never quietly starts spending someone else's credit. The same goes for a custom `base_url` — point the plugin at a local model and it stays pointed there.

### Other endpoints

`lunote_config.lua` is optional and overrides both `.env` and the defaults — copy `lunote_config.lua.sample` if you need it. Anything speaking the OpenAI chat-completions dialect works, so you can point the plugin at a local model served by [Ollama](https://ollama.com/blog/openai-compatibility):

```lua
local CONFIGURATION = {
    api_key = "ollama",
    model = "zephyr",
    base_url = "http://192.168.1.87:11434/v1/chat/completions",
    additional_parameters = {}
}

return CONFIGURATION
```

> **Note:** The prior `api_key.lua` style configuration is deprecated. Use `.env`, or `lunote_config.lua` for the settings above.

## Other Features

Additionally, as other extra features are rolled out, they will be optional and can be set in the `features` table in the `lunote_config.lua` file.

### Custom explanation prompt

The **Explain** button sends a built-in set of instructions asking for a plain-language explanation with the necessary background and context. If you want something different, set `explain_prompt` in the `features` table and it will be used instead.

```lua
local CONFIGURATION = {
    features = {
        explain_prompt = "Explain the highlighted passage to a ten year old, in two sentences."
    }
}

return CONFIGURATION
```

### Translation

To enable translation, you can set the `translate_to` parameter in the `features` table. For example, if you want to translate the text to French, you can set the `translate_to` parameter to `"French"`.

By setting the `translate_to` parameter, an **AI Translate** button is added to the highlight menu alongside **Explain**. This is useful if you are reading a book in a language you are not fluent in and want to understand a chunk of text in a language you are more comfortable with.

```lua
local CONFIGURATION = {
    features = {
        translate_to = "French"
    }
}

return CONFIGURATION
```

## Installation

If you clone this project, you should be able to put the directory, `lunote.koplugin`, in the `koreader/plugins` directory and it should work. If you want to use the plugin without cloning the project, you can download the zip file from the releases page and extract the `lunote.koplugin` directory to the `koreader/plugins` directory. If for some reason you extract the files of this repository in another directory, rename it before moving it to the `koreader/plugins` directory.

## How To Use

To use Lunote, simply highlight the text you want explained and select "Explain" from the highlight menu. The plugin sends the highlighted text to the ChatGPT API and shows the explanation in a pop-up window — there is nothing to type. From that window you can use "Ask Another Question" if you want to follow up on the passage.

If something goes wrong (missing API key, no credit on the account, no network), the plugin tells you what happened instead of closing KOReader. Errors reported by the API — an invalid key, an unknown model id, an exhausted balance — are shown verbatim, so a typo'd `OPENROUTER_MODEL` says so.

## Where your explanations go

Each explanation is saved in two places.

**Onto the highlight itself.** The passage becomes a highlight in the book (if it wasn't one already) and the explanation is attached as its note, after a `— Lunote —` separator. It therefore shows up in KOReader's own **Bookmarks** list next to your highlights and your own notes, and is picked up by the built-in Exporter. Any note you wrote yourself is kept and appended to, never overwritten. Set `features.save_to_notes = false` to switch this off.

**Into a local history.** A small SQLite database in `koreader/settings/lunote_history.sqlite3` keeps the full conversation, including any follow-up questions, grouped per book. Browse it from **Menu → Lunote → Browse saved explanations**, which works both while reading and from the file manager.

Roughly 1–3 KB per explanation, so a thousand of them is about 2 MB.

## Syncing to the web app

**Menu → Lunote** also has **Pair with web app** and **Sync to web app**. Pairing asks for the short code the web app shows you — six characters rather than a long token, because e-ink keyboards are painful. Sync then pushes your highlights, your notes and your explanations.

It is built for bad wifi. Work goes out in small batches and each is confirmed by the server before being marked done, so if the connection drops half way through, the batches that got there stay done and the next sync picks up where it stopped. Every record carries a stable id and the server matches on it, so re-sending can never duplicate anything. Sync only ever runs when you ask it to.

Push only: the device is the source of truth and the web app displays. Nothing is downloaded back.

The web app itself lives in [koreader-ai-plugin-webapp](https://github.com/memit0/koreader-ai-plugin-webapp) — a Next.js + Supabase project with a library view and a per-book page showing each highlight together with your note and its explanations. Its README covers setup and the device API contract.

## Syncing to an Obsidian vault

Lunote puts your reading into an [Obsidian](https://obsidian.md) vault as **one note per book**, holding every highlight from that book with the note you wrote on it and the explanations it generated, in reading order.

**Menu → Lunote → Sync now** pushes to the web app and to Obsidian in one go. Whichever of the two you have set up is what runs; each keeps its own record of what it has delivered, so a book that reached Obsidian but not the web app is only re-sent to the web app, and a sync that dies half way through picks up where it stopped.

### Setting it up

**Menu → Lunote → Obsidian vault → Connect to Obsidian…**

You need Obsidian's [Local REST API](https://github.com/coddingtonbear/obsidian-local-rest-api) community plugin, which puts a small server inside Obsidian for the reader to talk to. Install it, open its settings, and copy the API key. On the device, type the address of the machine Obsidian is running on — `192.168.1.20` is enough, it fills in HTTPS and port 27124 — and paste the key. It checks the connection straight away and tells you what answered, so a mistyped address fails there rather than silently later.

From then on, **Sync now** creates each book's note or replaces the one already there. **Test the connection** re-checks it, and **Write notes now** does the vault alone without touching the web app.

The reader has to be able to reach that machine: same wifi at home, or both on something like Tailscale. If Obsidian is closed or the laptop is asleep, the sync says so and the notes go the next time you ask — nothing is lost, they stay queued on the device.

### If your vault is on the e-reader instead

**Write to a folder instead…** takes a path on the device — e.g. `/mnt/us/Obsidian/Reading` on a jailbroken Kindle, or any folder Syncthing or Dropbox keeps in step with your computer. This needs no network at all, and **Write to the folder when a book is closed** (on by default) rewrites a book's note as you close it, so the vault is current before you have put the reader down.

You can use both. A folder on the device is a good offline copy; the network push is what gets it into Obsidian while you are still reading.

A note looks like this:

```markdown
---
title: "Critique of Pure Reason"
author: "Immanuel Kant"
highlights: 2
explanations: 1
updated: 2026-08-03 23:56
lunote_book: "fbdc7fcc80a6da31:book:1"
tags:
  - lunote
---

# Critique of Pure Reason

*Immanuel Kant*

## Chapter 1: The Moral Law

### p. 10 · 2026-07-29

> Act only according to that maxim whereby you can
> at the same time will that it should become a universal law.

^lunote-20260729100001

> [!note] Your note
> the categorical imperative

> [!abstract]- Explanation · google/gemini-2.5-flash-lite
> Kant is proposing a test for whether an action is right.
>
> **You:** Is this the golden rule?
>
> Not quite — the golden rule appeals to what you would want done to you.
```

Explanations are collapsed callouts, so a book with fifty highlights still reads as a list of passages. Each highlight carries a block id (`^lunote-…`) derived from the highlight itself, so `[[Critique of Pure Reason#^lunote-20260729100001]]` from one of your own notes keeps pointing at that passage.

> **Note:** a book's note is *generated*, not merged into — it is rewritten from the device whenever the book changes, so anything you type into it yourself will be lost. Write in your own notes and link to the blocks above.

This is independent of the web app: syncing to a vault does not need pairing, and neither destination consumes the other's work. You can use both, either, or neither.

> **On the certificate:** the Local REST API serves HTTPS with a self-signed certificate. The plugin does not verify it — trusting it would mean copying that certificate onto the e-reader, and the API key is what actually authenticates the request. This is a local address, so the exposure is someone already on your network; if that matters to you, turn on the plugin's plain-HTTP port and use `http://192.168.1.20:27123` instead, which is honest about it.

## Developing

Testing by copying to a device is painfully slow. [`dev/`](dev/) has a KOReader
simulator that runs the plugin's real code — real SQLite, real annotation
writes, real sync — from a terminal, plus a stub sync server so the whole loop
works with no API key and nothing deployed:

```sh
./dev/lunote-sim
lunote> open
lunote> select Act only according to that maxim…
lunote> explain
```

`dev/README.md` covers it, along with how to run the real KOReader desktop
emulator for anything visual. Automated tests are in `test/`; run `./test/run.sh`.

## Troubleshooting

**The "Explain" button doesn't appear in the highlight menu.** KOReader only discovers plugins in directories whose name ends in `.koplugin`, so the directory must be named exactly `lunote.koplugin` — a plain `git clone` gives you `Lunote` or `koreader-ai-plugin`, which is silently ignored. Check that it is in `koreader/plugins/`, and that "Lunote" is listed and ticked under Menu → Tools → More tools → Plugin management → User plugins. `koreader/crash.log` logs every directory that was scanned, and any plugin that failed to load.

I hope you enjoy using this plugin and that it enhances your e-reading experience. If you have any feedback or suggestions, please let me know!

If you want to support development, become a [Sponsor on GitHub](https://github.com/sponsors/drewbaumann).

License: GPLv3
