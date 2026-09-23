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
- **Remembers what worked**: Repeated commands become private macros on this Mac, retrieved before the model runs, so the third time costs milliseconds instead of a decision. Everything learned is listed in Settings, can be switched off, exported, and deleted.
- **Wake word with a kill switch**: "Hey pp" is gated by a microphone state machine that holds no audio until the phrase fires, and one click stops capture and discards the buffer.
- **Bring your own model**: Any package that passes the contract checks (architecture, tokenizer and special-token IDs, sequence layout, required heads) can be installed from Settings. A checkpoint that merely opens is not accepted.
- **Bring your own link, or your own API**: Paste a Hugging Face repository link (or any host) and pp downloads, checksums and smoke-tests the package. Or switch the whole decision step to your own endpoint — local or remote — and pp will send it the on-screen controls and your command.
- **Acts before you finish the sentence**: "Open Notes", "quit Slack" and "open a web address" name their target, so pp resolves the app while you are still talking and launches it the moment you stop. No screen read, no model call — around a third of a second, measured.

---

## Status and plans

- [docs/V2_PLAN.md](docs/V2_PLAN.md) — the v2 design: mid-sentence preemption, the island, alarms, the system lane, the browser lane, script synthesis behind four gates.
- [docs/V3_PLAN.md](docs/V3_PLAN.md) — the next pass from real use: one wake then a continuous session, hearing fixes, the web lane, WhatsApp, alarms that ring, and the notch-split island, with a prompt pack for each task.
- [docs/V2_SWOT.md](docs/V2_SWOT.md) — what in v2 is verified against the code, what only looks verified, and where the leverage is.
- [docs/V2_NEXT.md](docs/V2_NEXT.md) — the next pass, track by track and file by file, with exit gates.
- [docs/JEFF_BUILD_PLAN.md](docs/JEFF_BUILD_PLAN.md) — the reference for the model, the fixture method and packaging.

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
2. Download the decision model if it is not already in `~/Library/Application Support/pp/models`. The app bundle stays small; weights are fetched once, checksum-verified, smoke-tested, and activated atomically. After that, operation is offline.
3. Hold **Control–Option–Space** (or your custom shortcut), speak, and release.
4. Or invoke from the terminal:
```sh
scripts/say.sh "Open Finder"
```

---

## How It Works

Each decision cycle runs locally on Apple Silicon. Measured latency is in
[docs/BENCHMARKS.md](docs/BENCHMARKS.md) — a short question (router, safety, verifier) is
tens of milliseconds, a full target-selection question at the 512-token budget is a few
hundred, and a whole spoken step end to end is a few hundred milliseconds. That last
number is the one to quote, and it is measured on the machine in the benchmark file, not
assumed.

1. **Observe**: Traverses the active app's Accessibility tree. Each interactive element (buttons, tabs, inputs, menus) is converted into a structured candidate with its role, title, and coordinates.
2. **Plan**: `GrammarPlanner` parses compound instructions into sequential steps (`openApp`, `openURL`, `focusInput`, `typeText`, `pressKey`, `menu`, `click`).
3. **Decide**: The local **Laya 421M** MLX model evaluates candidates against the current state and goal, predicting the target element and verifying completion using its calibrated `noul` head.
4. **Safety Check**: `SafetyCritic` inspects candidate actions for destructive or outward effects; any high-risk action requires explicit user confirmation.
5. **Execute**: Synthesizes native macOS events (clicks, key presses, text insertion) via CoreGraphics.
6. **Verify**: Re-reads the screen, compares against the effect the step was supposed to have, and retries or replans within a bounded budget instead of repeating blindly.
7. **Remember**: Records what was acted on — the label of the control, never what it said — so a repeated command can be recalled as a macro. Credentials, one-time codes, secure fields, and clipboard contents are refused before anything is stored.

---

## Why it feels fast

Measured on this machine, in the app, driven by `scripts/say.sh`:

| Command | Path | Time |
| :--- | :--- | :--- |
| `open Finder` | name resolved, no screen read | ~370 ms |
| `/fast open Notes` | prepared mid-sentence, then launched | prepared in 237 ms, launched at once |
| `open google.com` | prepared mid-sentence (warm cache) | prepared in 1.5 ms, launched at once |
| `scroll down` | local grammar plan, one native action | ~390 ms |

The expensive part of a desktop command is never the model: it is reading the app in front.
On a quiet window that is ~200-400 ms; on a loaded browser page it was 3.1 seconds in
testing. So commands that name their target skip it entirely, and the ones that cannot are
read once and reused.

Type a command into the box in Settings, or from a terminal:

```sh
scripts/say.sh "open Notes"
scripts/say.sh "scroll down"
```

With `defaults write local.pp DebugHooks -bool true`, three test hooks appear:
`/probe` dumps what pp can see in the front window, `/act 14` performs control 14, and
`/fast open Notes` exercises the mid-sentence path without a microphone.

---

## Hands-Free & Wake Word

- **Hands-Free Mode**: Click **Start hands-free** in the widget. Speak a command and pause for ~1.5 seconds. `pp` executes the command and resumes listening.
- **Wake Word ("Hey pp")**: Enable in **Settings → Invoke the widget by saying "Hey pp"**. Uses macOS on-device speech recognition to trigger hands-free activation.

---

## Testing & Verification

```sh
# Run full test suite (186 tests, including 410/410 Laya MLX parity evaluation)
xcrun swift test

# Run desktop integration checks
./scripts/check-desktop.sh
```

The suite is layered: pure functions first (sequence building, shortlisting, safety rules,
coreference, macro mining), then Swift-versus-Python parity on committed fixtures, then
replay of recorded trees with no UI, no audio and no model weights. The parity suite is the
one that matters most: a ported encoder with sliding-window attention, per-layer RoPE theta
and a temperature bucket of 0.1 has many places to be quietly wrong, and quiet wrongness in
a decision model looks like a UX bug rather than a crash.

---

## What is not finished

Two things are contracts rather than complete products, and saying so is more useful than
pretending otherwise:

- **Browser and plugin adapters.** The adapter protocol, capability manifest, origin
  scoping, JSON-RPC plugin host, sandboxing rules and the shared conformance suite are
  implemented and tested. A Chromium MV3 extension, a Firefox/WebExtension adapter and a
  published plugin ecosystem are not, because they cannot be validated without those
  browsers and a real plugin to run against them.
- **Per-install LoRA training.** The versioned redacted training schema, the corpus, the
  compatibility checks, the evaluation gate (a candidate that regresses any blocking safety
  fixture is rejected no matter how accurate it is) and the byte-identical adapter store
  with rollback are implemented and tested. The training loop itself is not: it needs real,
  consented traces from an alpha that has not run yet, and faking it would produce a number
  nobody should believe.

---

## Architecture & Licenses

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full license details.
- **Laya**: Apache-2.0 (Convai Innovations Inc.)
- **ModernBERT**: Apache-2.0 (AnswerDotAI & LightOn)
- **MLX & MLX Swift**: MIT License (Apple Inc.)
- **Accessibility loop**: MIT License
