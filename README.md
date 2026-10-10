# Dynamic Terminal

A native macOS terminal that reads like a document.

Normal output is set in a proportional serif with generous line spacing. Anything
that needs a grid — code fences, box-drawing panels, full-screen apps — switches to
monospace automatically, so tables and TUIs stay aligned.

<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt="Dynamic Terminal icon"></p>

## Status

Early. It's my daily driver, but expect rough edges, especially with apps that
assume a fixed character grid.

## Requirements

- macOS 14 or later
- Swift 5.10+ (Xcode or Command Line Tools)

## Build

```sh
git clone --recurse-submodules https://github.com/HumanLemming996/Dexter.git
cd Dexter
./bundle.sh            # builds a release binary and opens DynamicTerminal.app
```

For a quick debug run: `swift build && .build/debug/DynamicTerminal`.

The repo ships a prebuilt `Sources/CVTerm/libvterm.a`. To rebuild it from the
`libvterm` submodule:

```sh
cd libvterm
make CFLAGS="-O2 -mmacosx-version-min=14.0"
cp .libs/libvterm.a ../Sources/CVTerm/
```

## Configuration

Settings live in `~/.dynamicterminal.json` (created on first launch) and can be
edited from the Settings window. You can change the proportional and monospace
fonts, sizes, line height, and the 16-colour ANSI palette.

If the configured proportional font isn't installed, the system font is used.

## Optional: local AI helpers

The app puts a few scripts on `PATH` inside its shells:

- `search <query>` — web results in the terminal
- `ai "question"`, `ai -cmd "task"`, `ai -fix` — answers and commands from a local
  model via [Ollama](https://ollama.com) (`mistral` by default)

Context tracking is **off by default**. To use it, add this to `~/.zshrc`:

```sh
[[ -n "$DT_RESOURCES" ]] && source "$DT_RESOURCES/context_hook.zsh"
```

Then run `ai -on` in a session. That starts Ollama if needed and begins logging
recent commands to `~/.dynamicterminal/` so `ai` has context. `ai -off` stops it.
Nothing leaves your machine except `search` queries (sent to DuckDuckGo), which `ai` may also make on your behalf.

## License

Apache 2.0 — see [LICENSE](LICENSE).
