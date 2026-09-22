# pp

**pp** is a 100% local, voice-controlled macOS assistant powered natively on Apple Silicon by **MLX Swift** and the **Laya 421M** decision model (`convaiinnovations/laya`).

You speak or type what you want; `pp` reads the current screen state through the macOS Accessibility tree (no screenshots), uses local on-device neural inference to select the target action, and executes it.

---

## Key Features

- **100% Offline by Default**: Operates completely disconnected from the internet. Zero cloud endpoints, zero telemetry, and zero mandatory API keys in the shipping binary.
- **Apple Silicon Native**: Laya 421M (ModernBERT 28-layer transformer + dual choice/noul classification heads) runs directly on the Apple Silicon GPU via Metal Performance Shaders using MLX Swift.
- **Local Multi-Step Planning**: Decomposes compound spoken commands ("open Safari and search for apple silicon") locally in 0ms using a deterministic `GrammarPlanner`.
- **Optional BYO-API (Bring Your Own API)**: If desired, users can enter a custom endpoint (OpenAI, OpenRouter, local Ollama/vLLM) in Settings for extended LLM planning.
- **Safety Critic**: Gated confirmation for destructive (`delete`, `trash`, `rmdir`), outward-facing (`send`, `post`, `tweet`, `mail`), and financial actions (`buy`, `pay`, `checkout`).
- **No Screenshots**: Inspects controls via native macOS Accessibility APIs. Passwords and secure input fields are never read.

---

## Quick Start

### Requirements
- macOS 14.2+ (Apple Silicon M1/M2/M3/M4)
- Xcode 15+ or Xcode 16+ command-line tools

### Building & Running
```sh
# 1. Build release app and DMG
./build.sh

# 2. Launch pp
open "$HOME/Applications/pp.app"
```

On first launch:
1. Allow **Accessibility** and **Microphone & Speech** permissions in System Settings.
2. Hold **Control–Option–Space** (or your custom shortcut), speak, and release.
3. Or invoke from the terminal:
```sh
scripts/say.sh "Open Finder"
```

---

## How It Works

Each decision cycle runs locally in ~60ms on Apple Silicon:

1. **Observe**: Traverses the active app's Accessibility tree. Each interactive element (buttons, tabs, inputs, menus) is converted into a structured candidate with its role, title, and coordinates.
2. **Plan**: `GrammarPlanner` parses compound instructions into sequential steps (`openApp`, `openURL`, `focusInput`, `typeText`, `pressKey`, `menu`, `click`).
3. **Decide**: The local **Laya 421M** MLX model evaluates candidates against the current state and goal, predicting the target element and verifying completion using its calibrated `noul` head.
4. **Safety Check**: `SafetyCritic` inspects candidate actions for destructive or outward effects; any high-risk action requires explicit user confirmation.
5. **Execute**: Synthesizes native macOS events (clicks, key presses, text insertion) via CoreGraphics.

---

## Hands-Free & Wake Word

- **Hands-Free Mode**: Click **Start hands-free** in the widget. Speak a command and pause for ~1.5 seconds. `pp` executes the command and resumes listening.
- **Wake Word ("Hey pp")**: Enable in **Settings → Invoke the widget by saying "Hey pp"**. Uses macOS on-device speech recognition to trigger hands-free activation.

---

## Testing & Verification

```sh
# Run full test suite (35 tests including 410/410 Laya MLX parity evaluation)
xcrun swift test

# Run desktop integration checks
./scripts/check-desktop.sh
```

---

## Architecture & Licenses

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full license details.
- **Laya**: Apache-2.0 (Convai Innovations Inc.)
- **ModernBERT**: Apache-2.0 (AnswerDotAI & LightOn)
- **MLX & MLX Swift**: MIT License (Apple Inc.)
- **Accessibility loop**: MIT License
