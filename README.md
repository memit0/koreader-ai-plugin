# AskGPT: ChatGPT Highlight Plugin for KOReader

Introducing AskGPT, a new plugin for KOReader that explains the parts of the book you're reading using ChatGPT, an AI language model. Highlight a passage, tap **Explain**, and you get the passage in plain language along with the background you need to follow it — no question to type. With AskGPT, you can have a more interactive and engaging reading experience, and gain a deeper understanding of the content.

## Getting Started

To use this plugin, You'll need to do a few things:

Get [KoReader](https://github.com/koreader/koreader) installed on your e-reader. You can find instructions for doing this for a variety of devices [here](https://www.mobileread.com/forums/forumdisplay.php?f=276).

If you want to do this on a Kindle, you are going to have to jailbreak it. I recommend following [this guide](https://www.mobileread.com/forums/showthread.php?t=320564) to jailbreak your Kindle.

Get an [OpenRouter API key](https://openrouter.ai/keys) and put it in a `.env` file inside the `askgpt.koplugin` directory — copy `.env.sample` and fill in your key:

```sh
OPENROUTER_API_KEY=sk-or-v1-...
```

That is the whole setup. The plugin defaults to `google/gemini-2.5-flash-lite`, which is cheap, fast and more than capable enough for explaining a paragraph of prose. To use a different one, pick any id from [openrouter.ai/models](https://openrouter.ai/models) and add:

```sh
OPENROUTER_MODEL=google/gemini-2.5-flash
```

> **Note:** `.env` is gitignored, so your key stays out of version control. Edits to it are picked up when KOReader restarts.

### Using OpenAI instead

Set `OPENAI_API_KEY` in `.env` rather than `OPENROUTER_API_KEY` and the plugin talks to OpenAI directly, defaulting to `gpt-4o-mini`. If both keys are present, OpenRouter wins; set `provider = "openai"` in `configuration.lua` to force the other way.

### Other endpoints

`configuration.lua` is optional and overrides both `.env` and the defaults — copy `configuration.lua.sample` if you need it. Anything speaking the OpenAI chat-completions dialect works, so you can point the plugin at a local model served by [Ollama](https://ollama.com/blog/openai-compatibility):

```lua
local CONFIGURATION = {
    api_key = "ollama",
    model = "zephyr",
    base_url = "http://192.168.1.87:11434/v1/chat/completions",
    additional_parameters = {}
}

return CONFIGURATION
```

> **Note:** The prior `api_key.lua` style configuration is deprecated. Use `.env`, or `configuration.lua` for the settings above.

## Other Features

Additionally, as other extra features are rolled out, they will be optional and can be set in the `features` table in the `configuration.lua` file.

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

If you clone this project, you should be able to put the directory, `askgpt.koplugin`, in the `koreader/plugins` directory and it should work. If you want to use the plugin without cloning the project, you can download the zip file from the releases page and extract the `askgpt.koplugin` directory to the `koreader/plugins` directory. If for some reason you extract the files of this repository in another directory, rename it before moving it to the `koreader/plugins` directory.

## How To Use

To use AskGPT, simply highlight the text you want explained and select "Explain" from the highlight menu. The plugin sends the highlighted text to the ChatGPT API and shows the explanation in a pop-up window — there is nothing to type. From that window you can use "Ask Another Question" if you want to follow up on the passage.

If something goes wrong (missing API key, no credit on the account, no network), the plugin tells you what happened instead of closing KOReader. Errors reported by the API — an invalid key, an unknown model id, an exhausted balance — are shown verbatim, so a typo'd `OPENROUTER_MODEL` says so.

## Where your explanations go

Each explanation is saved in two places.

**Onto the highlight itself.** The passage becomes a highlight in the book (if it wasn't one already) and the explanation is attached as its note, after a `— AskGPT —` separator. It therefore shows up in KOReader's own **Bookmarks** list next to your highlights and your own notes, and is picked up by the built-in Exporter. Any note you wrote yourself is kept and appended to, never overwritten. Set `features.save_to_notes = false` to switch this off.

**Into a local history.** A small SQLite database in `koreader/settings/askgpt_history.sqlite3` keeps the full conversation, including any follow-up questions, grouped per book. Browse it from **Menu → AskGPT → Browse saved explanations**, which works both while reading and from the file manager.

Roughly 1–3 KB per explanation, so a thousand of them is about 2 MB.

## Syncing to the web app

**Menu → AskGPT** also has **Pair with web app** and **Sync to web app**. Pairing asks for the short code the web app shows you — six characters rather than a long token, because e-ink keyboards are painful. Sync then pushes your highlights, your notes and your explanations.

It is built for bad wifi. Work goes out in small batches and each is confirmed by the server before being marked done, so if the connection drops half way through, the batches that got there stay done and the next sync picks up where it stopped. Every record carries a stable id and the server matches on it, so re-sending can never duplicate anything. Sync only ever runs when you ask it to.

Push only: the device is the source of truth and the web app displays. Nothing is downloaded back.

The web app itself lives in [koreader-ai-plugin-webapp](https://github.com/memit0/koreader-ai-plugin-webapp) — a Next.js + Supabase project with a library view and a per-book page showing each highlight together with your note and its explanations. Its README covers setup and the device API contract.

## Troubleshooting

**The "Explain" button doesn't appear in the highlight menu.** KOReader only discovers plugins in directories whose name ends in `.koplugin`, so the directory must be named exactly `askgpt.koplugin` — a plain `git clone` gives you `AskGPT` or `koreader-ai-plugin`, which is silently ignored. Check that it is in `koreader/plugins/`, and that "AskGPT" is listed and ticked under Menu → Tools → More tools → Plugin management → User plugins. `koreader/crash.log` logs every directory that was scanned, and any plugin that failed to load.

I hope you enjoy using this plugin and that it enhances your e-reading experience. If you have any feedback or suggestions, please let me know!

If you want to support development, become a [Sponsor on GitHub](https://github.com/sponsors/drewbaumann).

License: GPLv3
