# OmniVoice

[English](README.md) | [简体中文](README.zh-CN.md)

因为工作需要在 Mac 上通过 Horizon Client 在远程的 Windows 服务器里工作，尝试了市面上很多 STT 软件，比如 Typeless、豆包输入法、TypeNo，都没有办法在远程桌面上正常使用。最后只能自己 vibe coding 了一个 OmniVoice，主要就是为了解决 Horizon Client 里无法正常使用 STT 软件的问题。

## 快速开始

```bash
swift build
./.build/debug/OmniVoice doctor
./.build/debug/OmniVoice ui
```

如果你想启用本地 MLX 听写：

```bash
python3 -m venv .venv-mlx
.venv-mlx/bin/python -m pip install --upgrade pip setuptools wheel socksio mlx-whisper
./.build/debug/OmniVoice set-mlx-python .venv-mlx/bin/python
./.build/debug/OmniVoice set-mlx-model mlx-community/whisper-large-v3-turbo
./.build/debug/OmniVoice set-stt-acceleration mlx
```

说明：
- 仓库本身不包含 Whisper 模型二进制，也不包含 Hugging Face 缓存。
- 第一次运行 MLX 模式时，会从 Hugging Face 下载配置好的模型，可能需要几分钟。
- 本地历史记录、虚拟环境和 app bundle 构建产物默认不会纳入版本控制。

## 当前范围

- 本地 STT 默认支持 `Automatic Local`，优先使用 `whisper.cpp`，找不到时回退到 Apple Speech。
- `Ask Anything` 走云端优先的 provider 抽象，目前已经支持通用的 OpenAI-compatible API。
- 主流程中已经支持字典归一化。
- 文本插入策略会区分本地应用和远程桌面类应用。
- 剪贴板文本、剪贴板图片和最近截图上下文都可以在本地解析。
- 当前已支持通过保留剪贴板的自动化方式获取选中文本。

## 当前包结构

- `Sources/AppCore`
  核心模型、配置、字典归一化、STT 抽象、OpenAI-compatible Ask provider、上下文解析和插入规划。
- `Sources/Playground`
  一个可执行目标，用来运行 demo 流程、检查上下文解析结果，或者执行 Ask 请求。

## Ask Provider 配置

- 示例配置默认使用 `https://openrouter.ai/api/v1`。
- 你可以通过以下两种方式提供 API Key：
  - 在环境变量里设置 `OPENROUTER_API_KEY`
  - 保存到 macOS Keychain
- 如果没有 API Key，CLI 会回退到 mock provider，这样本地脚手架也能继续运行。

## 可编辑配置

- `Config/app-config.json`
  主应用和 provider 配置。
- `Config/dictionary.json`
  外部字典条目，适合处理中英混合术语和产品名。
- `OMNIVOICE_CONFIG_PATH`
  可选环境变量，用来指定另一份配置文件。
- 常用配置命令：
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
- 菜单栏应用当前也提供：
  - Setup 窗口，用来跑诊断、请求权限、自动检测 STT，并快速打开 Settings/Dictionary
  - Settings 窗口，用来编辑 STT、Ask 和快捷键
  - Dictionary 编辑器，用来管理目标术语和 spoken-form aliases
  - History 窗口，用来查看最近的 transcript 和 Ask response，并支持 copy/insert
  - 一键自动检测常见的 `whisper.cpp` 路径

## 全局快捷键

- `Config/app-config.json` 里包含 `hotkeys` 配置段。
- 默认绑定如下：
  - `Right Option`：开始 / 停止听写
  - `Command + Option + X`：Ask Selected Text
  - `Command + Option + C`：Ask Clipboard
  - `Right Option + Space`：Ask Screenshot
  - `Command + Option + D`：Doctor
- 快捷键可用人类可读格式编辑，例如 `cmd+opt+space` 或 `disabled`。
- 也可以通过 CLI 管理：
  - `./.build/debug/OmniVoice hotkeys`
  - `./.build/debug/OmniVoice set-hotkey askClipboard cmd+shift+c`
  - `./.build/debug/OmniVoice disable-hotkey runDoctor`

## 本地 STT

- 当前支持的本地 STT 模式：
  - `automaticLocal`
  - `appleSpeech`
  - `localWhisper`
- `stt.acceleration` 支持：
  - `cpu`
  - `auto`
  - `metal`
  - `mlx`
- `Config/app-config.json` 中包含 `stt.binaryPath` 和 `stt.modelPath`。
- `stt.threadCount` 可以固定 `whisper.cpp` 的线程数。
- `stt.promptInstruction` 可以覆盖默认的中英混合 STT prompt。留空时会继续使用根据当前中文脚本偏好自动生成的 prompt。
- `stt.mlxPythonPath` 指向安装了 `mlx-whisper` 的 Python 运行时。
- `stt.mlxModel` 支持本地 MLX 模型目录，也支持 Hugging Face repo，例如 `mlx-community/whisper-large-v3-turbo`。
- Settings 窗口里已经有 `MLX model preset` 下拉，可选 `Large V3 Turbo`、`Medium`、`Large V3`，也支持自定义 repo/path。
- 如果你想继续用本地 `whisper.cpp`，只需要把它的 CLI binary 和模型路径配置进去。
- `promptTerms` 用作轻量级术语提示列表。
- `autodetect-stt` 会扫描常见的 Homebrew、源码 build 和模型目录，并把检测到的路径写回配置。
- 如果 `automaticLocal` 找不到可用的 whisper binary 和 model，应用会回退到 Apple Speech。
- `threadCount` 留空时会使用保守的自动值，而不是盲目吃满所有核心。
- `auto` 加速会优先尝试 Metal，失败时在当前运行中回退到 CPU。
- `mlx` 模式通过外部 Python runtime 加 `mlx-whisper` 实现；仓库内当前使用的是 `.venv-mlx/bin/python`。
- 内置的 MLX runner 会直接解码 PCM WAV，所以应用录出来的 `.wav` 文件不依赖 `ffmpeg`。
- 非 WAV 音频在系统装了 `ffmpeg` 且可从 `PATH` 访问时也可以处理。

## MLX 安装

- 创建本地运行时：`python3 -m venv .venv-mlx`
- 安装依赖：`.venv-mlx/bin/python -m pip install --upgrade pip setuptools wheel socksio mlx-whisper`
- 让应用指向这套运行时：
  - `./.build/debug/OmniVoice set-mlx-python /absolute/path/to/.venv-mlx/bin/python`
  - `./.build/debug/OmniVoice set-mlx-model mlx-community/whisper-large-v3-turbo`
  - `./.build/debug/OmniVoice set-stt-acceleration mlx`
- 第一次运行会把配置好的 MLX 模型下载到 Hugging Face 本地缓存。

## CLI 示例

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

## 当前 UI 外壳

- `ui` 会启动一个最小可用的菜单栏应用。
- 当前菜单支持：
  - 开始 / 停止听写
  - 插入上一条 transcript
  - 插入上一条 answer
  - 复制上一条 transcript
  - 复制上一条 answer
  - 打开 History 查看最近 transcript / answer 事件
  - 从选中文本发起 Ask
  - 从剪贴板发起 Ask
  - 从最近截图发起 Ask
  - 检查自动上下文解析结果
  - 打开带实时诊断和快捷操作的 Setup 窗口
  - 查看当前快捷键
  - 打开可编辑的 Settings 窗口
  - 打开处理中英混合归一化规则的 Dictionary 编辑器
  - 自动检测本地 STT 路径
  - 打开配置文件
  - 请求权限
  - 跑 doctor 诊断
  - 退出
- 从 Settings 保存时，会重写 `Config/app-config.json`，把新的 Ask API key 存进 Keychain，并立即让后续的 dictation / Ask 请求使用新配置。
- 从 Dictionary 保存时，如果配置了外部字典文件，会重写 `Config/dictionary.json`，并重新加载归一化规则。

## 历史记录

- Ask 结果和 demo transcript 会追加写入 `Data/history.jsonl`。
- 可以通过设置 `OMNIVOICE_HISTORY_PATH` 把历史记录重定向到别的位置。

## 自动化权限

- 文本插入使用的是 macOS `System Events` 自动化。
- 选中文本抓取同样依赖 `System Events`，会先发送一次临时复制快捷键，再恢复之前的剪贴板内容。
- 通常你需要授予：
  - 对已构建 app 或终端的 Accessibility 权限
  - 如果要用 Apple Speech fallback，则需要 Speech Recognition 权限
  - 控制 `System Events` 的 Automation 权限
