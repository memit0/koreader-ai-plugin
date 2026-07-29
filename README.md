# AskGPT: ChatGPT Highlight Plugin for KOReader

Introducing AskGPT, a new plugin for KOReader that explains the parts of the book you're reading using ChatGPT, an AI language model. Highlight a passage, tap **Explain**, and you get the passage in plain language along with the background you need to follow it — no question to type. With AskGPT, you can have a more interactive and engaging reading experience, and gain a deeper understanding of the content.

## Getting Started

To use this plugin, You'll need to do a few things:

Get [KoReader](https://github.com/koreader/koreader) installed on your e-reader. You can find instructions for doing this for a variety of devices [here](https://www.mobileread.com/forums/forumdisplay.php?f=276).

If you want to do this on a Kindle, you are going to have to jailbreak it. I recommend following [this guide](https://www.mobileread.com/forums/showthread.php?t=320564) to jailbreak your Kindle.

Acquire an API key from an API account on OpenAI (with credits). Once you have your API key, create a `configuration.lua` file in the following structure or modify and rename the `configuration.lua.sample` file:

> **Note:** The prior `api_key.lua` style configuration is deprecated. Please use the new `configuration.lua` style configuration.

```lua
local CONFIGURATION = {
    api_key = "YOUR_API_KEY",
    model = "gpt-4o-mini",
    base_url = "https://api.openai.com/v1/chat/completions"
}

return CONFIGURATION
```

In this new format you can specify the model you want to use, the API key, and the base URL for the API. The model is optional and defaults to `gpt-4o-mini`. The base URL is also optional and defaults to `https://api.openai.com/v1/chat/completions`. This is useful if you want to use a different model or a different API endpoint (such as via Azure or another LLM that uses the same API style as OpenAI).

For example, you could use a local API via a tool like [Ollama](https://ollama.com/blog/openai-compatibility) and set the base url to point to your computers IP address and port.

```lua
local CONFIGURATION = {
    api_key = "ollama",
    model = "zephyr",
    base_url = "http://192.168.1.87:11434/v1/chat/completions",
    additional_parameters = {}
}

return CONFIGURATION
```

## Other Features

Additionally, as other extra features are rolled out, they will be optional and can be set in the `features` table in the `configuration.lua` file.

### Custom explanation prompt

The **Explain** button sends a built-in set of instructions asking for a plain-language explanation with the necessary background and context. If you want something different, set `explain_prompt` in the `features` table and it will be used instead.

```lua
local CONFIGURATION = {
    api_key = "YOUR_API_KEY",
    model = "gpt-4o-mini",
    features = {
        explain_prompt = "Explain the highlighted passage to a ten year old, in two sentences."
    }
}
```

### Translation

To enable translation, you can set the `translate_to` parameter in the `features` table. For example, if you want to translate the text to French, you can set the `translate_to` parameter to `"French"`.

By setting the `translate_to` parameter, an **AI Translate** button is added to the highlight menu alongside **Explain**. This is useful if you are reading a book in a language you are not fluent in and want to understand a chunk of text in a language you are more comfortable with.

```lua
local CONFIGURATION = {
    api_key = "YOUR_API_KEY",
    model = "gpt-4o-mini",
    base_url = "https://api.openai.com/v1/chat/completions",
    features = {
        translate_to = "French"
    }
}
```

## Installation

If you clone this project, you should be able to put the directory, `askgpt.koplugin`, in the `koreader/plugins` directory and it should work. If you want to use the plugin without cloning the project, you can download the zip file from the releases page and extract the `askgpt.koplugin` directory to the `koreader/plugins` directory. If for some reason you extract the files of this repository in another directory, rename it before moving it to the `koreader/plugins` directory.

## How To Use

To use AskGPT, simply highlight the text you want explained and select "Explain" from the highlight menu. The plugin sends the highlighted text to the ChatGPT API and shows the explanation in a pop-up window — there is nothing to type. From that window you can use "Ask Another Question" if you want to follow up on the passage.

If something goes wrong (missing API key, no credit on the account, no network), the plugin now tells you what happened instead of closing KOReader.

## Troubleshooting

**The "Explain" button doesn't appear in the highlight menu.** KOReader only discovers plugins in directories whose name ends in `.koplugin`, so the directory must be named exactly `askgpt.koplugin` — a plain `git clone` gives you `AskGPT` or `koreader-ai-plugin`, which is silently ignored. Check that it is in `koreader/plugins/`, and that "AskGPT" is listed and ticked under Menu → Tools → More tools → Plugin management → User plugins. `koreader/crash.log` logs every directory that was scanned, and any plugin that failed to load.

I hope you enjoy using this plugin and that it enhances your e-reading experience. If you have any feedback or suggestions, please let me know!

If you want to support development, become a [Sponsor on GitHub](https://github.com/sponsors/drewbaumann).

License: GPLv3
