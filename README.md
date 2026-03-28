# OmniVoice

[English](README.md) | [简体中文](README.zh-CN.md)

I work on a Mac but need to access remote Windows servers through Horizon Client. I tried a number of STT tools on the market, including Typeless, Doubao Input Method, and TypeNo, but none of them worked properly inside the remote desktop session. In the end, I vibe-coded OmniVoice to solve the specific problem of STT not being usable inside Horizon Client. For the speech-to-text part alone, OmniVoice runs fully locally, does not require any API, and does not cost money to use.

## Quick Start

```bash
swift build
./.build/debug/OmniVoice doctor
./.build/debug/OmniVoice ui
```

For local MLX dictation:

```bash
python3 -m venv .venv-mlx
.venv-mlx/bin/python -m pip install --upgrade pip setuptools wheel socksio mlx-whisper
./.build/debug/OmniVoice set-mlx-python .venv-mlx/bin/python
./.build/debug/OmniVoice set-mlx-model mlx-community/whisper-large-v3-turbo
./.build/debug/OmniVoice set-stt-acceleration mlx
```

Notes:
- The repository does not ship Whisper model binaries or Hugging Face caches.
- The first MLX run downloads the configured model from Hugging Face and can take several minutes.
- Local history, virtual environments, and app bundles are intentionally excluded from version control.

## Current scope

- Local STT defaults to `Automatic Local`, which prefers `whisper.cpp` when available and falls back to Apple Speech when it is not.
- Ask Anything is modeled as a cloud-first provider layer and now supports real OpenAI-compatible APIs.
- Dictionary normalization is part of the main pipeline.
- Insertion planning distinguishes local apps from remote session clients.
- Clipboard text, clipboard image, and recent screenshot contexts can now be resolved locally.
- Selected-text capture is supported through a clipboard-preserving automation fallback.

## Current package structure

- `Sources/AppCore`
  Core models, configuration, dictionary normalization, STT abstraction, OpenAI-compatible Ask provider support, context resolution, and insertion planning.
- `Sources/Playground`
  A small executable that can run the demo pipeline, inspect resolved context, or execute an Ask request.

## Ask provider setup

- The sample config defaults to `https://openrouter.ai/api/v1`.
- You can use either:
  - `OPENROUTER_API_KEY` in the environment
  - a saved API key in macOS Keychain
- Without an API key, the CLI falls back to a mock provider so the local scaffold still runs.

## Editable config

- `Config/app-config.json`
  Main app/provider configuration.
- `Config/dictionary.json`
  External dictionary entries for mixed Chinese-English terminology and product names.
- `OMNIVOICE_CONFIG_PATH`
  Optional override for loading a different config file.
- Useful config commands:
  - `./.build/debug/OmniVoice config`
  - `./.build/debug/OmniVoice set-stt-mode automaticLocal`
  - `./.build/debug/OmniVoice set-stt-binary /path/to/whisper-cli`
  - `./.build/debug/OmniVoice set-stt-model /path/to/model.bin`
  - `./.build/debug/OmniVoice set-stt-acceleration cpu`
  - `./.build/debug/OmniVoice set-stt-acceleration auto`
  - `./.build/debug/OmniVoice set-stt-acceleration mlx`
  - `./.build/debug/OmniVoice set-stt-threads 10`
  - `./.build/debug/OmniVoice set-stt-threads auto`
  - `./.build/debug/OmniVoice set-stt-prompt-instruction "请使用简体中文与 English 混合输出，保留术语大小写。"`
  - `./.build/debug/OmniVoice clear-stt-prompt-instruction`
  - `./.build/debug/OmniVoice set-mlx-python /absolute/path/to/python`
  - `./.build/debug/OmniVoice set-mlx-model mlx-community/whisper-large-v3-turbo`
  - `./.build/debug/OmniVoice autodetect-stt`
  - `./.build/debug/OmniVoice set-ask-model openrouter/auto`
  - `./.build/debug/OmniVoice set-ask-base-url https://openrouter.ai/api/v1`
  - `./.build/debug/OmniVoice set-ask-api-key <key>`
  - `./.build/debug/OmniVoice clear-ask-api-key`
- The menu bar app also exposes:
  - a Setup window with diagnostics, permission requests, STT auto-detection, and quick links into Settings/Dictionary
  - a Settings window for STT, Ask, and hotkeys
  - a Dictionary editor for target terms and spoken-form aliases
  - a History window for recent transcripts and Ask responses, with copy/insert actions
  - one-click STT auto-detection for common `whisper.cpp` paths

## Global hotkeys

- `Config/app-config.json` now includes a `hotkeys` section.
- Default bindings are:
  - `Right Option` for dictation toggle
  - `Command + Option + X` for Ask Selected Text
  - `Command + Option + C` for Ask Clipboard
  - `Right Option + Space` for Ask Screenshot
  - `Command + Option + D` for Doctor
- Hotkeys are editable as human-readable shortcuts such as `cmd+opt+space` or `disabled`.
- You can also manage them from CLI:
  - `./.build/debug/OmniVoice hotkeys`
  - `./.build/debug/OmniVoice set-hotkey askClipboard cmd+shift+c`
  - `./.build/debug/OmniVoice disable-hotkey runDoctor`

## Local STT

- Supported local STT modes are:
  - `automaticLocal`
  - `appleSpeech`
  - `localWhisper`
- `stt.acceleration` supports:
  - `cpu`
  - `auto`
  - `metal`
  - `mlx`
- `Config/app-config.json` includes `stt.binaryPath` and `stt.modelPath`.
- `stt.threadCount` lets you pin a whisper.cpp thread count.
- `stt.promptInstruction` lets you override the default mixed-language STT prompt. Leave it empty to keep the automatic prompt derived from the current Chinese script preference.
- `stt.mlxPythonPath` points at the Python runtime that has `mlx-whisper` installed.
- `stt.mlxModel` accepts either a local MLX model directory or a Hugging Face repo such as `mlx-community/whisper-large-v3-turbo`.
- The Settings window now includes an `MLX model preset` picker for `Large V3 Turbo`, `Medium`, `Large V3`, plus a custom repo/path field for anything else.
- Point them at your local `whisper.cpp` or compatible CLI binary and model file.
- `promptTerms` is used as a lightweight keyterm hint list.
- `autodetect-stt` searches common Homebrew, repo-build, and model directories and writes any detected paths back into config.
- If `automaticLocal` cannot find a working whisper binary and model, the app falls back to Apple Speech.
- Leaving `threadCount` empty uses a conservative auto value instead of blindly using every core.
- `auto` acceleration prefers Metal and falls back to CPU if the GPU path fails during the current app run.
- `mlx` runs through an external Python runtime plus `mlx-whisper`; the repo-local setup I used is `.venv-mlx/bin/python`.
- The bundled MLX runner decodes PCM WAV directly, so app-recorded `.wav` files do not require `ffmpeg`.
- Non-WAV audio can still be handled through `ffmpeg` when it is installed and available on `PATH`.

## MLX Setup

- Create a local runtime with `python3 -m venv .venv-mlx`
- Install dependencies with `.venv-mlx/bin/python -m pip install --upgrade pip setuptools wheel socksio mlx-whisper`
- Point the app at that runtime:
  - `./.build/debug/OmniVoice set-mlx-python /absolute/path/to/.venv-mlx/bin/python`
  - `./.build/debug/OmniVoice set-mlx-model mlx-community/whisper-large-v3-turbo`
  - `./.build/debug/OmniVoice set-stt-acceleration mlx`
- The first run downloads the configured MLX model from Hugging Face into the local cache.

## CLI examples

```bash
./.build/debug/OmniVoice demo
./.build/debug/OmniVoice context --source auto
./.build/debug/OmniVoice context --source selected
./.build/debug/OmniVoice ask --source clipboard "解释一下我刚复制的内容"
./.build/debug/OmniVoice ask --source selected "解释一下我当前选中的内容"
./.build/debug/OmniVoice ask --source screenshot "这张截图里的报错是什么意思？"
./.build/debug/OmniVoice insert --source auto "把这段文字贴到当前输入框"
./.build/debug/OmniVoice transcribe sample.wav --source auto --insert
./.build/debug/OmniVoice history
./.build/debug/OmniVoice doctor
./.build/debug/OmniVoice request-permissions
./.build/debug/OmniVoice last-transcript
./.build/debug/OmniVoice last-answer
./.build/debug/OmniVoice copy-last-transcript
./.build/debug/OmniVoice copy-last-answer
./.build/debug/OmniVoice insert-last-transcript --source auto
./.build/debug/OmniVoice insert-last-answer --source auto
./.build/debug/OmniVoice ui
```

## Current UI shell

- `ui` launches a minimal menu bar app.
- The menu currently supports:
  - Start / stop dictation
  - Insert last transcript
  - Insert last answer
  - Copy last transcript
  - Copy last answer
  - Open History for recent transcript/answer events
  - Ask from selected text
  - Ask from clipboard
  - Ask from recent screenshot
  - Inspect resolved automatic context
  - Open a Setup window with live diagnostics and quick actions
  - Show configured hotkeys
  - Open an editable Settings window for STT, Ask, and hotkeys
  - Open a Dictionary editor for mixed Chinese-English normalization rules
  - Auto-detect local STT paths
  - Open the config file
  - Request permissions
  - Run doctor diagnostics
  - Quit
- Saving from Settings rewrites `Config/app-config.json`, stores any new Ask API key in Keychain, and applies the updated runtime to new dictation and Ask requests immediately.
- Saving from Dictionary rewrites `Config/dictionary.json` when an external dictionary file is configured and reloads normalization rules for future dictation runs.

## History

- Ask results and demo transcripts are appended to `Data/history.jsonl`.
- Set `OMNIVOICE_HISTORY_PATH` to redirect history storage elsewhere.

## Automation permissions

- Text insertion uses macOS automation through `System Events`.
- Selected-text capture also uses `System Events` to issue a temporary copy shortcut and then restores the previous clipboard.
- You should expect to grant:
  - Accessibility permissions to the built app or terminal
  - Speech Recognition permission if you want to use the Apple Speech fallback backend
  - Automation permission for controlling `System Events`
