# pp v2.1 — next steps, file by file

Plan only, written 2026-09-23 after reading the working tree and running `swift build`,
`swift test` (182 passing), `scripts/check-desktop.sh` and `scripts/check-voice.sh`.

Companion documents: `docs/V2_SWOT.md` (what is real and what is not), `docs/V2_PLAN.md` (the v2
design), `docs/JEFF_BUILD_PLAN.md` (the model and packaging reference).

Naming: the work below is numbered N1…N8 so it does not collide with v2's phases A…I.

## 0. Ground rules for this pass

1. **No confirmation is printed for work that did not happen.** Today's alarm path reports
   success after opening Clock.app. Everything below assumes that rule is absolute.
2. **Every new lane is deterministic first.** If a lane can be a parser, it is a parser. The
   model is the last resort, not the first.
3. **Every lane ships with a replay test** — a recorded input and an expected action sequence
   that runs in milliseconds with no UI, no audio and no weights.
4. **Every action that changes state is read back** before it is reported.
5. Commit before starting. The v2 work is currently uncommitted on top of `3cdefab`.

## 1. Stack map

| Layer | Technology | Lives in | Why this one |
| :-- | :-- | :-- | :-- |
| Shell and island | SwiftUI inside an AppKit `NSPanel` (`.nonactivatingPanel`, `.statusBar`) | `Sources/PpDesktop/IslandView.swift`, `IslandController.swift`, `PpDesktopApp.swift` | SwiftUI for the content, AppKit for the window behaviour. A panel that never takes focus is only reliable outside SwiftUI's window management. |
| Speech in | `AVFoundation` + `Speech` (`SFSpeechRecognizer`, `requiresOnDeviceRecognition`) with the local `EnergyEOU` endpointer | `SpeechInput.swift`, `EnergyEOU.swift`, `WakePhrase.swift` | Zero bundle cost, on-device, auto-updating. Parakeet EOU stays an optional download behind `SpeechProvider`. |
| Decision model | MLX Swift, in process | `Sources/PpMLX/*` | Already at 100% top-1 parity on 410 fixtures, mean 62 ms. Nothing new needed here. |
| Fast lanes | Pure Swift parsers, no I/O | `PpCore/DirectIntent.swift`, `SystemIntent.swift` (new), `TimeIntent.swift` (new) | Sub-millisecond, fully unit-testable, no screen read and no model. |
| Planning | `GrammarPlanner` offline, optional LLM behind `PlannerSeam` (user endpoint or MLX Qwen) | `PpCore/Planner.swift`, `PlannerSeam.swift` | Offline by default; the LLM is a setting, not a dependency. |
| System control | `NSAppleScript` for Apple Events, `Process` for `pmset`/`screencapture`/`networksetup`, `dlopen` for DisplayServices brightness | `PpDesktop/SystemExecutor.swift` (new) | Read-back is mandatory, so the executor owns both the call and the probe. |
| Time and alarms | `UserNotifications` (`UNUserNotificationCenter`) plus a JSON store | `PpCore/AlarmStore.swift` (new), `PpDesktop/AlarmScheduler.swift` (new) | Fires with pp quit. Clock.app has no AppleScript dictionary, so it cannot be driven reliably. |
| Browser | Chrome DevTools Protocol over `URLSessionWebSocketTask`; MV3 extension over native messaging (stdio) | `PpDesktop/CDPClient.swift` (new), `extensions/chrome/*` (new), `Resources/pp.browser.host.json` (new) | Element indices instead of screenshots. Native messaging is stdio framed with a 4-byte length prefix — not a Unix socket; the plan guessed wrong and stdio is what Chrome actually supports. |
| Memory | SQLite plus JSONL, all local | `PpCore/EventLog.swift`, `PersonalizationStore.swift`, `LearningRecorder.swift`, `LearnedSkills.swift` (new) | Inspectable, exportable, deletable. Never a training set by default. |
| Packaging | Developer ID, hardened runtime, notarytool, stapled DMG | `scripts/sign-and-notarize.sh`, `Resources/pp.entitlements` | `com.apple.security.automation.apple-events` is already present; verify it, do not assume it. |

---

## Track N1 — Truth and correctness (1.5 days, do this first)

**Goal:** remove every statement the app makes that the code does not back up, and fix the two
defects that make the demo look unfinished.

### N1.1 `cooldown` is unreachable, and stability counts never decay

| File | Change |
| :-- | :-- |
| `Sources/PpCore/PreemptionPolicy.swift` | Move the cooldown check above the `.supersede` block so it applies to every preempt, not only the first. Replace `observationCounts: [String: Int]` with a counted-with-timestamp window (drop entries older than ~10 s) so a phrase said twice an hour apart is not "stable". Reset `superseded` when the observed target changes. |
| `Tests/PpCoreTests/PreemptionPolicyTests.swift` | Add: cooldown blocks a second preempt of a different target inside 1.5 s; a clause repeated after a 30 s gap is not treated as already stable; `.supersede` is still allowed exactly once per target change. |

### N1.2 The remainder must be raw text, not normalised text

Contract row 3 ("the exact spoken substring") fails today: `takeRemainder` slices the lowercased
string, so "write Sumit's number" becomes `sumit's number`.

| File | Change |
| :-- | :-- |
| `Sources/PpCore/DirectIntent.swift` | Add `public static func tokenSpans(_ text: String) -> [(text: String, range: Range<String.Index>)]` — the normalised token plus the range it came from in the original string. |
| `Sources/PpCore/PreemptionPolicy.swift` | Rewrite `takeRemainder(full:consumed:)` to match the consumed tokens against the spans and slice `full` with those ranges. Guarantee, and assert in tests: the result is a substring of the original transcript, byte for byte. Keep the mid-word rule (return `nil` rather than a fragment) and the connector stripping ("and", "then", "and then"). |
| `Tests/PpCoreTests/PreemptionPolicyTests.swift` | Fixtures: proper nouns, apostrophes, an email address, a URL, a phone number, trailing punctuation, "and then", mid-word, empty remainder, non-prefix transcript. |
| `Tests/DesktopChecks/main.swift`, `Tests/VoiceChecks/main.swift` | Update the expected remainders, and add one case with a capitalised name so the old behaviour cannot come back. |

### N1.3 The executor stops lying

| File | Change |
| :-- | :-- |
| `Sources/PpDesktop/Desktop.swift:1448-1487` | `executeSystemAction` returns a value that carries `verified: Bool` and the read-back string. Delete the alarm and timer branches entirely (N2 replaces them); until N2 lands, "set alarm" must return an explicit "alarms are not available in this build", which the island shows as an error. Lock uses ⌃⌘Q and verifies with `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`, not `pmset displaysleepnow`. Volume and dark mode read their state back. Screenshot returns the file path. |
| `Sources/PpDesktop/PpDesktopApp.swift:399`, `:831` | Route every parsed action through `SafetyCritic` before executing, the same way `performDirect` does at `:934`. |
| `Tests/PpCoreTests/SystemActionTests.swift` | Add the negative: an action that cannot be verified reports failure, never a confirmation. |

### N1.4 One window, not two

| File | Change |
| :-- | :-- |
| `Sources/PpDesktop/PpDesktopApp.swift:2019-2034` | Stop creating the 244×202 `VoiceWidget` panel in `showOverlay`; show the island only and keep its frame autosave under one name (`pp.island`). Keep `VoiceWidget` compiled but behind `DebugHooks` for the developer path. |
| `Sources/PpDesktop/IslandController.swift` | Confirm the panel is created once, is reused, and is positioned top-centre 8 pt under the menu bar of the screen with the pointer. |
| `Tests/PpCoreTests/IslandStateTests.swift` (new) | Ten lines: sizes per state, auto-hide durations (result 2.5 s, error 6 s, working nil), and the reduce-motion path. |

**Exit gate N1:** `swift test` green; a scripted partial stream in `check-desktop.sh` proves the
cooldown; one window is on screen while the island is up; `grep -rn "2ms\|180ms" Tests` returns
nothing (see N6).

### N1.6 Two small debts worth paying while you are in here

`bash scripts/check-desktop.sh` currently prints `installTap(onBus:bufferSize:format:block:) was
deprecated in macOS 27.0` from `SpeechInput.swift:114`. The target machine is macOS 27, so switch
the capture path to the non-deprecated API in this pass rather than letting the warning become
background noise. The second debt is `observationCounts` never being cleared — N1.1 covers it —
and the third is that `Sources/PpCore/SystemAction.swift` and `SystemIntent.swift` must not both
exist once N3 starts.

---

## Track N2 — Alarms and timers that actually fire (3–4 days)

**Goal:** contract row 9. An alarm set by voice rings when pp is closed.

| File | Change |
| :-- | :-- |
| `Sources/PpCore/TimeIntent.swift` (new) | The enum from `docs/V2_PLAN.md` §C.2: `alarm`, `timer`, `remind` (Calendar), `list`, `cancel(target:)`, `none`. Parsing for "7 am", "half past six", "quarter to nine", "seven fifteen", "in twenty minutes", "an hour and a half", bare hours resolved to the next occurrence with AM/PM stated back. |
| `Sources/PpCore/NumberWords.swift` (new) | "fifty" → 50, "a quarter" → 25, "half" → 50, "ten percent" → 10, "seven fifteen" → 7:15. Shared with the volume lane, which needs it too. |
| `Sources/PpCore/AlarmStore.swift` (new) | `[ScheduledItem]` persisted with `PpJSON` to `~/Library/Application Support/pp/alarms.json`; `next(after:)`, `cancel(id:)`, DST-safe via `Calendar.nextDate(after:matching:)`; past times roll forward. |
| `Sources/PpDesktop/AlarmScheduler.swift` (new) | `UNUserNotificationCenter`: authorisation requested at the moment the first alarm is set (never at launch), `UNCalendarNotificationTrigger` for alarms, `UNTimeIntervalNotificationTrigger` for timers, `interruptionLevel = .timeSensitive` so Focus does not swallow it, a bundled sound, a repeating re-arm for snooze, and `getPendingNotificationRequests` as the read-back. |
| `Sources/PpDesktop/PpDesktopApp.swift` | Route `TimeIntent` before `SystemActionParser`; raise the island while an alarm rings and accept "stop" as a dismissal. |
| `Tests/PpCoreTests/TimeIntentTests.swift` (new, ~40 cases), `AlarmStoreTests.swift` (new), `Tests/DesktopChecks/main.swift` | Parse table, persistence round-trip, next-fire across midnight and across a DST boundary, cancel semantics, list. |

**Stack note:** a local notification is the only mechanism that rings with the app quit. Verify
early that `.timeSensitive` is honoured on this macOS build without an extra entitlement; if it
is silently demoted, fall back to a normal alert and say so in the setup copy rather than
discovering it during a demo.

**Exit gate N2:** set an alarm two minutes out, quit pp, hear it fire; reopen pp and the alarm is
still listed; cancel it by voice.

---

## Track N3 — Finish the system lane (4–5 days)

**Goal:** the Siri-parity set, minus the parts that need private APIs you should not ship.

| File | Change |
| :-- | :-- |
| `Sources/PpCore/SystemIntent.swift` (new) | The enum from `docs/V2_PLAN.md` §D.1 (`volume`, `brightness`, `darkMode`, `doNotDisturb`, `lockScreen`, `sleepDisplay`, `screenSaver`, `screenshot`, `emptyTrash`, `wifi`, `bluetooth`, `music`, `openSettings`). Replaces `SystemAction.swift`; delete the old file so there is one vocabulary. |
| `Sources/PpDesktop/SystemExecutor.swift` (new) | One method per intent, each returning a read-back value. `Desktop.swift` keeps the AX and window code and loses the AppleScript branches. |
| `Tests/PpCoreTests/SystemIntentTests.swift` (new) | Every row of §D.1's parse table, three phrasings each, plus the negatives ("skip forward 30 seconds" is not a timer, "turn up the volume" without a number is `.up(10)`). |

Per-action decisions, so this does not turn into a week of guessing:

| Action | Implementation | Read-back | Risk |
| :-- | :-- | :-- | :-- |
| Volume | AppleScript `set volume output volume N` / `output volume of (get volume settings)` | the number | safe |
| Dark mode | AppleScript `System Events` appearance preferences | `dark mode of appearance preferences` | safe |
| Lock | ⌃⌘Q via `System Events` keystroke, or `SACLockScreenImmediate` if available | `CGSessionCopyCurrentDictionary` | safe |
| Sleep display / screen saver | `pmset displaysleepnow`, `open -a ScreenSaverEngine` | none needed | safe |
| Screenshot | `screencapture -x` to `~/Desktop`, optional `-c` to the clipboard | the file path, and say it out loud | safe |
| Music | AppleScript to Music: `playpause`, `next track`, `previous track` | `player state` and the current track | safe |
| Empty trash | Finder AppleScript, behind a spoken confirmation | `count of items in trash` | confirm |
| Wi-Fi | `networksetup -setairportpower <port> on/off` (resolve the port by matching "Wi-Fi" in `-listallhardwareports`) | `-getairportpower` | confirm |
| Focus / Do Not Disturb | allowlisted `shortcuts run` only | re-read with the same shortcut | confirm |
| Brightness | `dlopen` DisplayServices (`DisplayServicesGetBrightness`/`SetBrightness`), mark it experimental, fail visibly if the symbol is missing | the level | safe, experimental |
| Bluetooth | **not in v2.1.** Toggling needs a private framework or a third-party binary; neither belongs in a signed DMG. Say "not supported yet" and offer Shortcuts. | — | — |

**Exit gate N3:** "volume to fifty percent" in one pass with no model and a read-back; "empty
trash" asks first and refuses to guess; "lock my screen" locks and the read-back confirms it.

---

## Track N4 — Give the browser lane a transport (8–10 days)

`DOMIndexer` is correct and orphaned. Row 4 of the contract needs one of the two transports
below; build CDP first because it needs nothing installed in the browser except a launch flag.

| File | Change |
| :-- | :-- |
| `Sources/PpDesktop/BrowserDiscovery.swift` (new) | Find a debuggable browser: read `DevToolsActivePort` from each Chromium user-data directory, then probe `127.0.0.1:9222/9229/9333` with `GET /json/version`. Return the WebSocket URL and the target list. |
| `Sources/PpDesktop/CDPClient.swift` (new) | `URLSessionWebSocketTask` with an id/response correlation table, `Runtime.evaluate` with `returnByValue`, and `Input.dispatchMouseEvent` for the click. Timeouts on every call. |
| `Sources/PpCore/DOMIndexer.swift` | Keep it pure. Add an initialiser that takes the extension's payload as well as a CDP payload, so both transports produce identical indexed rows. |
| `Sources/PpCore/BrowserAdapter.swift` (new) | An `AdapterProtocol` conformance: capability manifest, origin scoping, fallback order (plugin → extension → debugging protocol → AX → ask). |
| `extensions/chrome/manifest.json`, `content.js`, `background.js` (new) | MV3, `nativeMessaging` + `activeTab` + `scripting`, `run_at: document_idle`; the content script walks visible interactive elements and posts the same index rows over `chrome.runtime.sendNativeMessage`. |
| `Resources/pp.browser.host.json` (new) | Native-messaging host manifest, `allowed_origins` pinned to the extension ID, `type: stdio`. The first-run installer copies it to `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`. |
| `Sources/PpCore/Onboarding.swift` | A step that offers the CDP path (with the launch-flag explanation) and the extension path, and states which one is active afterwards. |
| `Tests/PpCoreTests/BrowserAdapterTests.swift` (new), `Tests/PpMLX` unaffected | The shared conformance suite over both transports, origin scoping, and a fixture asserting password fields, `autocomplete=cc-*` and payment iframes never appear in a payload. |

**Exit gate N4:** on a recorded page, "click the documentation link" resolves to the right index
over CDP and over the extension, with no screenshot call anywhere in the path.

---

## Track N5 — Finish synthesis, and make the gates hard to walk around (5–6 days)

| File | Change |
| :-- | :-- |
| `Sources/PpCore/ScriptGates.swift` | Remove the `probability: 1.0` default so gate 4 cannot be skipped by omission. Ban `do shell script` outright in v2.1. Run gate 3 against the *string literals of the compiled artifact* (`osacompile`, then `osadecompile`, then extract literals) so `set p to "/Us" & "er/bin"` no longer walks past a substring denylist. Cap script length. |
| `Sources/PpMLX/ScriptVerdict.swift` or extend `QuestionBuilder.swift` | Gate 4 becomes a real Laya `noul` question: "does this script achieve: <goal>" with the script body, threshold 0.4, read through `DecisionProvider`. No proposal runs without it. |
| `Sources/PpDesktop/ScriptRunner.swift` (new) | `NSAppleScript` with `executeAndReturnError`, a wall-clock timeout, and the result recorded against the expected effect. |
| `Sources/PpCore/LearnedSkills.swift` (new) | `learned.json` in Application Support, written only after a verified effect, retrieved before synthesis, listed in the personalization panel, deleted by "Delete everything". |
| `Sources/PpCore/PlannerSeam.swift` | One implementation per proposer: the user's configured endpoint, and optionally MLX Qwen behind the model manager. The proposer sees the goal and the front app **and never page text**, which is the prompt-injection answer. |
| `Tests/PpCoreTests/ScriptGateTests.swift` | Adversarial set: read `~/.ssh/id_rsa`, delete Downloads, `curl | sh`, open Terminal, base64 shell, concatenated path, empty `tell … to return`, plus one legitimate window-snap script that must pass all four gates. Add: a rejected script leaves no trace in `learned.json`. |

**Exit gate N5:** "snap this window to the left half" proposes, gates, runs and caches; the second
attempt is model-free; nothing in the adversarial set executes.

---

## Track N6 — Measurement, with no invented numbers (2–3 days)

| File | Change |
| :-- | :-- |
| `Sources/PpCore/Timing.swift` (new) | Named marks (`asr.partial`, `preempt.decide`, `preempt.act`, `asr.final`, `route`, `read`, `decide`, `act`, `verify`) collected in an actor, emitted as one log line and appended to `~/Library/Application Support/pp/timing.jsonl` per session. |
| `Sources/PpDesktop/PpDesktopApp.swift` | Replace the three ad-hoc marks with `Timing` calls at the nine points above. |
| `Tests/VoiceChecks/main.swift:33` | **Delete the printed constants.** Print a summary computed from a scripted run, or print nothing. |
| `Sources/PpDesktop/PpDesktopApp.swift` (dev hook) | `--transcribe <file.wav>` using `SFSpeechURLRecognitionRequest`, so ASR p50/p95 can be measured headlessly against `fixtures/voice/*.wav`. |
| `scripts/bench-voice.sh` (new) | Replays the four clips, runs the preemption policy over the scripted partial stream, and writes the table. |
| `docs/BENCHMARKS.md` | Add a per-lane table (time to first action, time to decision, time to screen read) with p50/p95, the machine, and the macOS build. Sample thermals once with `powermetrics` during a ten-minute session. |

**Exit gate N6:** every latency number in the docs traces to a line in `timing.jsonl`; `grep -rn
"(2ms\|180ms\|(<500ms)" Tests scripts` is empty.

---

## Track N7 — Packaging, permissions, onboarding (2–3 days)

| File | Change |
| :-- | :-- |
| `Resources/pp.entitlements` | `com.apple.security.automation.apple-events` is already there. Add nothing else; verify rather than assume. |
| `scripts/sign-and-notarize.sh` | After signing, dump and assert the entitlements with `codesign -d --entitlements -`, then `stapler validate` the DMG. Fail the script if the dump is missing the Apple Events key. |
| `Sources/PpCore/Onboarding.swift` | New `PermissionKind` cases: `appleEvents`, `calendars`, `notifications`. The enum is `CaseIterable`, so the settings list and the polling flow pick them up. Explain *why* before the prompt appears, then deep-link the pane. |
| `Sources/PpDesktop/PpDesktopApp.swift` | Settings copy: which lane each command takes, that alarms live in pp and not in Clock, and that Bluetooth is not supported yet. |
| `docs/PP_V2_SAFETY_REVIEW.md` | Extend the six invariants to cover system actions, alarms and synthesis: read-back required, no unverified confirmation, proposer never sees screen text, partials only reach the allowlist. |
| `docs/RELEASE_CHECKLIST.md` (new) | The manual pass: TCC on a clean account, revoke Accessibility, deny notifications, quit-and-reopen alarm, network-off run, signature checks, upgrade over a previous build. |

**Exit gate N7:** a clean account installs, grants the three permissions through the app's own
flow, and runs a voice command with Wi-Fi off; the signature and entitlement dump come back clean.

---

## Track N8 — Deferred work, each with its trigger

| Item | Trigger that unblocks it | Reason it is not now |
| :-- | :-- | :-- |
| Phase 8 app adapters (WhatsApp, Zen workspaces, Shortcuts) | an accuracy suite exists and names the worst app | selectors are a day each against a moving target; the suite decides the order, not a guess |
| Phase 7B per-install LoRA | ≥200 consented traces and a replay+safety suite that can grade a candidate | a candidate that cannot be graded must not be promoted; the schema and rollback machinery already exist |
| Hinglish voice | a batch recogniser passes a WER gate on the command vocabulary | English-only streaming EOU cannot be marketed as Hinglish |
| Qwen planner as a default | the grammar planner's exact-match rate is measured and below the bar | 2.3 GB and a cold-start hit for a lane that is currently offline and instant |

---

## 2. Order, dependencies and cost

| Track | Days (one dev, part-time) | Depends on | Unlocks |
| :-- | :-- | :-- | :-- |
| N1 Truth and correctness | 1.5 | — | a demo that survives a careful viewer |
| N2 Alarms and timers | 3–4 | N1.3 | contract row 9, and the first "Siri can't do that offline" feature |
| N3 System lane | 4–5 | N1.3, N2 (shares `NumberWords`) | contract row 2 and most of the long tail |
| N6 Measurement | 2–3 | N1 | every later claim being checkable |
| N4 Browser transport | 8–10 | N6 (to prove the latency) | contract row 4, Electron apps |
| N5 Synthesis | 5–6 | N3, N6 | contract row 5, growth without releases |
| N7 Packaging and permissions | 2–3 | N2, N3 | a build that can be handed to someone else |

Total for N1 through N7: **26–33 days part-time**, and N1+N2+N6 is about a week of it. N4 and N5
are the only tracks that can slip without blocking the demo, which is why they come last.

## 3. Definition of done for v2.1

- An alarm set by voice fires with pp quit, and cancelling it by voice actually cancels it.
- "open the notes app and write down meeting notes" launches Notes mid-sentence and types the
  remainder with the original capitalisation.
- Nothing in the UI, the logs, or the docs reports a latency number or a success that was not
  measured or verified.
- One window appears when pp is woken; it never takes focus.
- Every action that changes state has a read-back, and the unverifiable ones are gone.
- The adversarial suites (safety, script, privacy) run in `swift test` and cannot be made to pass
  a dangerous command by phrasing.
- `grep -rin "typesafe\|openrouter" Sources` finds only documentation comments.
- Every number in `docs/BENCHMARKS.md` traces to `timing.jsonl`, with the machine named.

## 4. Tomorrow, in order

1. Commit the v2 tree.
2. Track N1 in one sitting: cooldown ordering, raw remainder, one window, no fabricated
   confirmations. It is a day and a half and it removes every weakness that a careful viewer
   would find.
3. Delete the hardcoded timing prints in `Tests/VoiceChecks/main.swift` (they are two lines).
4. Start N2 with `TimeIntent` and `AlarmStore` — pure, fast, testable — before touching
   notifications.
5. While N2 is in review, run the app once with `log stream --predicate 'subsystem == "local.pp"'`
   and write down the real partial-to-launch numbers for Notes, Finder and Safari.

## 5. Verification commands

```sh
swift build
swift test
swift test --filter PreemptionPolicyTests
bash scripts/check-desktop.sh
bash scripts/check-voice.sh
log stream --predicate 'subsystem == "local.pp"' --style compact      # live marks
powermetrics --samplers thermal -i 5000 -n 120                        # ten-minute thermal pass
codesign -d --entitlements - ~/Applications/pp.app                    # entitlement dump after N7
```
