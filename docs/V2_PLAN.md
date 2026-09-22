# pp v2 — the mid-sentence assistant

Implementation plan for the demo behaviour: say **"hey pp, open the notes app and write down
meeting notes"**, and Notes is on screen *before the sentence ends*, with the rest of the
sentence carried out after. Plus the things a person expects to be there anyway: alarms and
timers, volume, dark mode, lock, screenshots, a browser that works by element rather than by
screenshot, and a way to learn a command nobody wrote a tool for.

Status: plan only. Nothing in this document has been built. Part II is written against the
code as it exists today, so the first job is to *not* rebuild things that are already here.

Written 2026-09-23. Supersedes `docs/JEFF_BUILD_PLAN.md` for anything about latency, the
decision loop, and the safety gates; that document is still correct about the model, the
fixtures and the packaging.

---

## Part I — What is being built

### 1.1 The behaviour contract

| # | When the user does this | pp must | Bar |
| :-- | :-- | :-- | :-- |
| 1 | Says "open the notes app and write down meeting notes" | Launch Notes **while the sentence is still being spoken**, then do the rest of the sentence in Notes | Notes front **< 500 ms after the word "Notes"** |
| 2 | Says "set the output volume to fifty percent" | Extract `volume_adjust(50)` in one pass, no token generation | < 150 ms, zero LLM streaming |
| 3 | Says "search google for quantum annealing papers" | Type `quantum annealing papers` — the exact spoken substring | No paraphrase, no LLM text |
| 4 | Says "click the documentation link" on a page | Pick the element by DOM index and click it natively | No screenshot, < 400 ms |
| 5 | Says a command no tool covers ("toggle dark mode") | Synthesise, gate, run, then remember it | Runs once slowly, then < 200 ms forever |
| 6 | Says "open Terminal and delete my Downloads folder" | Refuse immediately, before anything runs | Hard refusal, no code execution |
| 7 | Says "hey pp" (even whispered) | The island appears and starts listening | Island visible < 120 ms after the phrase matches |
| 8 | Says "thank you" | Stop, close the island, stop the microphone | Microphone closed within one buffer |
| 9 | Says "set an alarm for 7 am" | A real alarm that fires with pp closed | Fires within ±2 s, audible, with the app quit |

Behaviours 1–6 are the viral demo's test battery. 7–9 are what makes it a thing a person can
actually live with. Everything in this plan exists to serve one of the nine rows above.

### 1.2 What "fast" means here

Three different waits get conflated in every demo write-up. Keep them apart:

- **Time to first action** — from a word being recognised to the app/effect appearing. This is
  what row 1 is about, and it is won by *starting before the sentence ends*, not by a faster
  model. The model is not in this path at all.
- **Time to a decision** — from the finished sentence to a chosen action. Won by not reading
  the screen when the words already name the target.
- **Time to a screen read** — the real cost centre. Measured on this machine: **398 ms** on
  Finder, **3,123 ms** on a loaded Safari page. Nothing else in the pipeline is close.

The demos quote the first number and quietly imply the third. Our acceptance tests measure all
three separately (see §11).

---

## Part II — What already exists (do not rebuild)

Measured on this machine, 2026-09-23, app installed at `~/Applications/pp.app`, model at
`~/Library/Application Support/pp/models/laya-mlx`, 199 tests green.

| Area | Lives in | State | Missing for v2 |
| :-- | :-- | :-- | :-- |
| Deterministic command parse | `Sources/PpCore/DirectIntent.swift` | openApp/quitApp/openSite, `.none` for anything ambiguous; `AppNameMatcher` | system + time intents (§7, §6) |
| Name → app, no screen read | `Sources/PpDesktop/AppResolver.swift` | running apps, then installed scan, cached 60 s | nothing |
| Screen read + actions | `Sources/PpDesktop/Desktop.swift` | AX capture, candidate table, `perform`, `activateApplication`, `quitApplication` | CDP/browser lane (§8) |
| Decision model loop | `PpDesktopApp.runCycles`, `PpCore/Decision.swift` | working live (`cycle 2: DONE 90% conf 0.88`) | nothing |
| Streaming speech | `Sources/PpDesktop/SpeechInput.swift` | `shouldReportPartialResults`, `EnergyEOU`, wake phrase, `finish()`; **no `onPartial` callback** | partial callback + preemption (§4) |
| Wake state machine | `PpCore/WakeWordController.swift`, `PpCore/WakePhrase.swift` | retention + kill switch + tests | whisper tuning, "thank you" (§5) |
| Language model of *this Mac* | `PpCore/LearningRecorder.swift`, `PpDesktop/AssistantMemory.swift`, `EventLog`, `MacroMiner`, `RankingFeatures`, `PersonalizationStore` | records steps, mines macros, reorders candidates, inspect/export/delete | nothing |
| Safety | `PpCore/SafetyCritic.swift` | five risk categories, gate on outward/destructive/system | script gates (§9) |
| Model install | `PpMLX/ModelSources.swift` (Hugging Face links), `ModelInstaller`, `ModelDownloader`, `BYOMPackageValidator` | link or folder, resume, checksum, smoke test, rollback | nothing |
| Your own decision service | `Settings → Custom API`, `PpCore/HTTPProvider.swift`, `DecisionEndpoint` | toggle + URL + key, keyless endpoints allowed | nothing |
| Onboarding / permissions | `PpCore/Onboarding.swift` + `Settings` | polls TCC, deep-links the right pane | Apple Events string (§7.5) |
| Overlay | `PpDesktopApp.showOverlay`, `VoiceWidget`, `PixelField` | 244×202 floating panel, autosaved position | island restyle + state machine (§5) |
| Time, alarms, sounds | — | **nothing exists** | all of §6 |
| System actions | — | **nothing exists** | all of §7 |
| Browser DOM | — | **nothing exists** (AX only) | all of §8 |
| Script synthesis + gates | `PpCore/PlannerSeam.swift` (seam only) | proposal seam exists | all of §9 |

Useful invariants already pinned by tests — keep them true, and extend rather than weaken:
`AdversarialSafetyTests`, `PrivacyFilterTests`, `LearningRecorderTests`, `DirectIntentTests`,
`WakeWordControllerTests`, `VerifierTests`, `UpdateChannelTests`.

---

## Part III — Architecture

### 3.1 Four lanes, one coordinator

```
mic ─► SpeechInput ─┬─ partial ─► PreemptionPolicy ──(allowlist)──► Desktop.activate/perform
                    │                                            (lane 1: PREEMPT)
                    │                     └─ else: warm the AX read for the front app
                    └─ final ──► IntentRouter
                                   ├─ DirectIntent      ─► AppResolver ─► native call  (lane 2: FAST)
                                   ├─ SystemIntent      ─► SystemExecutor (AppleScript)  (lane 2)
                                   ├─ TimeIntent        ─► AlarmStore/Scheduler          (lane 2)
                                   └─ otherwise         ─► GrammarPlanner ─► Laya loop   (lane 3: MODEL)
                                                                   └─ no tool fits ─► ScriptProposer ─► 4 gates
                                                                                        (lane 4: SYNTH)
```

Rules that make it safe and fast:

1. **Lane 1 may act on a partial. Lanes 2–4 may not.** Lane 1 is an allowlist of effects that
   are visible, reversible and cheap to repeat (launch, focus, open a URL, quit). Nothing that
   sends, deletes, buys, or changes a setting fires from a partial — ever.
2. **Lane 2 never reads the screen.** If the words name the target, the screen has nothing to
   contribute. This is where the 3.1 s Safari capture gets skipped.
3. **Lane 3 reads the screen exactly once per cycle** and reuses that read as the first cycle's
   snapshot (`firstSnapshot:` already threads through `runCycles`).
4. **Lane 4 always gates.** Four gates (§9.2), in order, all of them blocking.

### 3.2 The latency budget, per stage

| Stage | Today (measured) | After v2 | How |
| :-- | :-- | :-- | :-- |
| ASR partial → word visible | in flight | same | already streaming |
| Partial → preempt decision | n/a | **1–5 ms** | pure parse + resolve, cached |
| Preempt → app front | n/a | 150–400 ms | `NSWorkspace.openApplication`, no AX read |
| Final transcript → lane pick | ~2 ms | ~2 ms | `IntentRouter` |
| Lane 2 action | 300–500 ms | 300–500 ms | native call |
| Lane 3 first cycle | 400–3,100 ms | 400 ms typical | skip the read when the name is known; reuse it otherwise |
| Laya decision | tens–hundreds of ms | same | already measured, per bucket |

Target for row 1: **< 500 ms from the word "Notes" to Notes in front**, achieved while the user
still has three words left to say. That is not a latency win, it is an ordering win — which is
exactly why it looks impossible in the demo.

---

## Phase A — Preemption (mid-sentence action)

**Goal:** row 1 of the contract. This is the demo.

### A.1 Speech layer

`Sources/PpDesktop/SpeechInput.swift`:

- Add `var onPartial: ((String) -> Void)?` and call it wherever `transcript` is assigned from a
  recognition result (there is currently no such callback; partials only reach the app through
  the `@Published` value).
- Add `var onClauseClosed: (() -> Void)?` fired when `EnergyEOU` reports `.endOfUtterance`
  (already wired for endpointing; expose the event rather than only using it internally).
- **Amend the comment at `SpeechInput.swift:275`** ("Never execute partial text…"). It becomes:
  *partial text may only drive the preempt allowlist; it must never reach the planner, the
  model, or any effect outside that allowlist.* The invariant survives, scoped. Say so in the
  comment, because the next reader will otherwise think it was deleted.

`Sources/PpCore/PartialRouter.swift` already has `consider(partial:) -> Readiness` and
`mayAct(partial:clauseClosed:)`. Keep them for lane-3 pre-warming; preemption gets its own
policy object because its rules are different (stability, allowlist, reversibility).

### A.2 `PreemptionPolicy` (new, `Sources/PpCore/PreemptionPolicy.swift`)

Pure, no AppKit, fully testable. Interface:

```swift
public struct PartialObservation: Equatable, Sendable {
    public let clause: String      // normalised transcript so far
    public let isFinal: Bool
    public let monotonicTime: TimeInterval
}

public enum PreemptionDecision: Equatable, Sendable {
    case wait
    case preempt(step: PlanStep, clause: String)   // clause = the text being consumed by it
    case supersede(step: PlanStep, clause: String) // a different target than the one already taken
}

public struct PreemptionPolicy: Sendable {
    public init(minimumStableObservations: Int = 2,
                minimumCharacters: Int = 8,
                allowed: Set<PlanStep.Kind> = [.openApp, .quitApp, .openURL],
                cooldown: TimeInterval = 1.5)

    /// Feed every partial, in order. Returns what to do about it, if anything.
    public mutating func observe(_ observation: PartialObservation) -> PreemptionDecision
}
```

Rules, in order — each one is a test:

1. `isFinal` never preempts (the final path owns it; double-execution is the bug to prevent).
2. The clause must parse via `DirectIntentParser` to a kind in `allowed`. Otherwise `.wait`.
3. The clause must be **stable**: byte-identical to the previous observation, at least
   `minimumStableObservations` times. One flicker of a misheard partial must not launch
   anything. This single rule is the difference between "magic" and "why is Photos open".
4. At least `minimumCharacters` characters. "op" is not a command.
5. A minimum gap (`cooldown`) since the last preempt, so a stuttering recogniser cannot fire
   five launches.
6. If a preempt already happened and the new clause names a *different* target, return
   `.supersede` — do not silently keep the old one. Document the trade-off: the first app may
   already be open. Both are visible; neither is destructive.

Also expose `public func takeRemainder(full: String, consumed: String) -> String?` — the text
after the preempted clause, computed on the normalised strings, used by the final path.

### A.3 Coordinator wiring (`PpDesktopApp`)

- `speech.onPartial` → `preemption.observe` → on `.preempt`, run the action **immediately** via
  the existing `performDirect(_:)` path, remember `Preempted(step:clause:at:)`, show the island
  with the action ("Opening Notes…"), and log a `preempt:` line with the elapsed ms.
- `speech.onFinal` → if something was preempted: `takeRemainder(full: final, consumed: clause)`
  - empty remainder → the command is done; report the preempted result and stop.
  - non-empty remainder → `run(remainder, in: frontmostAppNow)` — Notes is in front, so the
    lane-3 loop reads Notes, not the app the user was in before. This is what makes "…and write
    down meeting notes" work with no extra machinery.
- `Memory`: `memory.begin(clause:)` at the preempt, `memory.record(...)` at the preempt action,
  and a *separate* trace for the remainder. Two commands in one sentence, honestly recorded.
- Cancel: Escape during a preempted session kills the island and stops the microphone; the
  launched app stays (closing it automatically is a surprise, not an undo).

### A.4 Tests

`Tests/PpCoreTests/PreemptionPolicyTests.swift`

- fires on the second identical stable partial, not the first
- never fires on `isFinal`
- never fires for `type_text`, `click`, `open_folder`, or any kind outside the allowlist
- never fires for a clause that isn't deterministic ("open the thing I was looking at")
- does not fire twice inside `cooldown`
- a mid-sentence correction returns `.supersede` with the new target, once
- a partial that stops matching (user said "open notes… never mind") returns `.wait`
- `takeRemainder` maths: exact prefix, trailing connector words ("and", "then"), no remainder,
  remainder that starts mid-word (must return nil, never a mangled string)

`Tests/DesktopChecks/main.swift` additions: `DirectIntentParser` + `PreemptionPolicy` compiled
standalone (add `Sources/PpCore/PreemptionPolicy.swift` to the file list in
`scripts/check-desktop.sh`).

### A.5 Exit gate

Live, on this machine: say "open the notes app and write down meeting notes". Notes must be the
frontmost app before the last two words are spoken (watch the island and the log timestamps),
and the remainder must place the cursor in a new note. Then the adversarial half: say "open
notes… actually open reminders" and confirm only Reminders is left in front.

---

## Phase B — The island, the wake, and "thank you"

**Goal:** rows 7–9 of the contract, and the thing that makes it feel like a product rather than
a script.

### B.1 Island instead of widget

Today: one 244×202 panel (`PpDesktopApp.showOverlay`, autosave name `DesktopVoiceWidget`) that
shows the pixel-word canvas and a status line. Replace its layout, keep its plumbing.

New: `Sources/PpDesktop/IslandView.swift` + `IslandController.swift`.

- Shape: a 220×34 capsule (idle) → 420×64 (listening) → 520×96 (working, with a one-line
  status). Animate with `matchedGeometryEffect`-free explicit frames so it works on macOS 14.2
  (the package's floor).
- Position: top centre, 8 pt under the menu bar of the *screen with the pointer*, remembered
  per display. `NSPanel` keeps: `.borderless`, `.nonactivatingPanel`, `level = .statusBar`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `hidesOnDeactivate = false`.
  It must never take focus — a panel that steals the keyboard mid-typing is worse than a slow
  assistant.
- States, as an explicit enum so they can be unit-tested:

```swift
@MainActor final class IslandController {
    enum Mode: Equatable { case hidden, wake, listening, working(String), result(String), error(String) }
    func show(_ mode: Mode, autoHideAfter: TimeInterval? = nil)
    func hide(animated: Bool)
}
```

- Auto-hide: `.result` hides after 2.5 s; `.error` after 6 s; `.working` never (it is replaced).
- Hover expands to show the transcript; click on the island focuses nothing, but a small ✕ cross
  cancels, and Escape cancels from anywhere.
- Reduce-motion respected; VoiceOver label carries the same text as the status line; contrast
  checked against a wallpaper, so use a material background plus a 1 px border.

### B.2 Whispered wake

- `PpCore/WakePhrase.swift` already matches fuzzy variants ("hey p p", "hey pee pee", "hey
  jeff"). Add the quiet-speech failure modes: a dropped leading "h" ("ey pp"), a swallowed
  second word ("hey—"), and the bare "pp" when the mic level is low and nothing else has been
  said for a while. Add each as a test in `Tests/DesktopChecks/main.swift` (that file already
  holds the phrase battery).
- `SpeechInput`: set `request.requiresOnDeviceRecognition = true` when available (faster and
  more private), and keep `contextualStrings = ["Hey pp", "pp"]`.
- `EnergyEOU.Config`: whispered speech has a lower RMS than the current gate expects. Add a
  `whisperCeiling` to the config so quieter input still counts as speech for endpointing, and
  test it with the existing scripted-buffer tests in `check-desktop.sh`.
- Do **not** add a volume threshold to the wake decision. A gate that needs a loud phrase is the
  classic reason a wake word "works on my desk but not in a meeting".

### B.3 "Thank you" closes it

New, `Sources/PpCore/DismissalPhrase.swift`:

```swift
public enum DismissalPhrase {
    /// True when the clause is nothing but a sign-off, or ends with one.
    public static func isDismissal(_ clause: String) -> Bool
    /// The command part of "open notes thank you" → "open notes".
    public static func commandWithoutSignOff(_ clause: String) -> String?
}
```

- Matches: "thank you", "thanks", "thanks pp", "thank you pp", "that's all", "that is all",
  "stop", "stop listening", "goodbye", "bye", "never mind", "cancel".
- `stop` and `cancel` must dismiss **and** cancel any work in flight — they are the same action
  as Escape, and they are the words a person reaches for when something is going wrong.
- Wire: in `onFinal`, before anything else, if the whole clause is a dismissal → `dismiss()`;
  if it ends with one → strip it and run the command part.
- After a dismissal with wake enabled: hide the island, stop the microphone, return to
  `wake.armForWake()`. If wake is disabled, hide the island and stop listening entirely. The
  microphone must be closed within one buffer (this is the privacy promise; `WakeWordController`
  already tracks it and there is a test for it).

### B.4 Tests and exit gate

`Tests/PpCoreTests/DismissalPhraseTests.swift` (12+ cases, including the negatives: "thank you
for the notes" is not a dismissal when it is the whole command, "stop the music" is a command
not a dismissal, "cancel my subscription" must not be treated as cancel).

Exit gate: "hey pp" whispered at arm's length opens the island within 120 ms; "open Notes thank
you" opens Notes and closes the island; the microphone indicator goes out within one buffer.

---

## Phase C — Time: alarms, timers, reminders

**Goal:** row 9. Explicitly asked for, and the clearest thing Siri does that pp does not.

### C.1 Decide first: where does an alarm live?

macOS Clock.app has **no AppleScript dictionary**. So there are three honest options:

| Option | Works with pp closed | Shows in Clock.app | Cost |
| :-- | :-- | :-- | :-- |
| A. Own store + `UNUserNotificationCenter` | yes | no | small, offline, testable — **recommended** |
| B. Calendar.app event with an alarm (AppleScript) | yes | no (shows in Calendar) | medium, needs Apple Events + TCC |
| C. Drive Clock.app through the AX tree | no | yes | fragile, needs the app open, not offline |

Take **A** for v2.0, add **B** as "remind me to…" (a distinct intent, honestly labelled as a
Calendar event). Write the choice into the Settings copy so nobody expects to find it in Clock.

### C.2 `TimeIntent` (new, `Sources/PpCore/TimeIntent.swift`)

```swift
public enum TimeIntent: Equatable, Sendable {
    case alarm(at: DateComponents, label: String?)   // hour/minute, 24 h resolved
    case timer(seconds: Int, label: String?)
    case remind(DateComponents, text: String)
    case list
    case cancel(target: CancelTarget)
    case none
    public enum CancelTarget: Equatable, Sendable { case all, alarms, timers, named(String), soonest }
}
```

Parsing rules (each one a test):

- "set an alarm for 7 am" / "wake me at 6:30" / "half past six" / "quarter to nine" / "seven
  fifteen". Resolve ambiguous bare hours ("alarm for 7") to the next occurrence of that hour, and
  **say which one in the confirmation** ("7 pm" is a surprise at breakfast).
- "in twenty minutes" / "for ten minutes" / "an hour and a half" → timer.
- "remind me to call Diya at 5" → Calendar event; needs a title, so refuse politely if there is
  none.
- "what alarms do I have" / "cancel my 7 am alarm" / "cancel all timers" / "quiet the alarm".
- Never parse a duration out of a different command ("skip forward 30 seconds" is not a timer).
  Reuse `CommandInput`'s duration reader only after `TimeIntent` has claimed the clause.

### C.3 `AlarmStore` + `AlarmScheduler` (new, PpCore + PpDesktop)

- `AlarmStore` (`Sources/PpCore/AlarmStore.swift`): `[ScheduledItem]` persisted with `PpJSON` to
  `~/Library/Application Support/pp/alarms.json`; `next(after:)`; `cancel(id:)`; DST-safe via
  `Calendar.nextDate(after:matching:)`.
- `AlarmScheduler` (`Sources/PpDesktop/AlarmScheduler.swift`): `UNUserNotificationCenter`
  request/authorisation, one notification per item (`UNCalendarNotificationTrigger` /
  `UNTimeIntervalNotificationTrigger`), interruption level `.timeSensitive` so it survives Focus,
  plus the app's own sound when pp happens to be running, plus a repeating re-arm for snooze.
- Also raise the island on fire so the user sees *what* is ringing and can say "stop".
- Tests: `AlarmStoreTests` (persistence round-trip, next-fire across midnight, across DST, past
  times roll forward, cancel semantics), `TimeIntentTests` (≈40 cases), and a scheduler test with
  the existing `TestClock` (`Sources/PpCore/PlannerSeam.swift`).

### C.4 Exit gate

Set an alarm two minutes out, quit pp, wait. It fires, audibly, at the right second, and is still
listed when pp reopens. Then cancel it by voice.

---

## Phase D — System commands (the Siri-parity set)

**Goal:** row 2, and the "whatever Siri can do" list, scoped to what is actually deterministic.

### D.1 A separate lane, not more `PlanStep.Kind`

`PlanStep.Kind` is the *planner's* closed vocabulary and callers switch on it exhaustively. Do not
add twelve AppleScript cases to it. Add:

`Sources/PpCore/SystemIntent.swift`

```swift
public enum SystemIntent: Equatable, Sendable {
    case volume(Level)          // .set(Int 0...100), .up(Int), .down(Int), .mute, .unmute
    case brightness(Level)
    case darkMode(Bool?)        // nil = toggle, and report the new state
    case doNotDisturb(Bool?)
    case lockScreen
    case sleepDisplay
    case screenSaver
    case screenshot(Target)     // .screen, .window, .region, .clipboard
    case emptyTrash
    case wifi(Bool?)
    case bluetooth(Bool?)
    case music(Transport)       // .play, .pause, .next, .previous, .whatIsPlaying
    case openSettings(SettingsPane)
    case none

    public enum Level: Equatable, Sendable { case set(Int), up(Int), down(Int) }
}
```

Parse table — every row is a test with at least three phrasings, including "fifty" → 50,
"half" → 50 for volume, "a quarter" → 25, "max"/"full" → 100, "ten percent" → 10.

### D.2 Execution

`Sources/PpDesktop/SystemExecutor.swift`: one method per intent, each returning a *verifiable*
result (`"Volume 50%"` after reading it back, not "done"). Use `NSAppleScript`/`osascript` where
the system has no API (dark mode, Do Not Disturb, empty trash) and native calls where it does
(`NSScreen`, `CGDisplay`, `NSSound`, `MPMusicPlayerController`/`osascript` for Music). Screenshots
go through `screencapture` into `~/Desktop` with a dated filename.

Every action is classified by `SafetyCritic` before it runs:

| Action | Verdict |
| :-- | :-- |
| volume, brightness, dark mode, music, screensaver, lock, sleep | safe |
| screenshot | safe (but say where it went) |
| wi-fi/Bluetooth off, empty trash, Do Not Disturb off→on | `requiresConfirmation` |
| anything touching files outside the user's own folders | vetoed |

### D.3 Info.plist and entitlements — easy to forget, blocks the phase

- `Resources/Info.plist` currently has **no `NSAppleEventsUsageDescription`**. Add it, or every
  `osascript` call fails silently or prompts with a blank reason.
- Add `com.apple.security.automation.apple-events` to the entitlements used by
  `scripts/sign-and-notarize.sh` for the notarized build.
- Calendar/Reminders intents additionally need `NSCalendarsUsageDescription` /
  `NSRemindersUsageDescription` and the matching TCC grants; surface them through
  `OnboardingCoordinator` (`PermissionKind` gains two cases — that enum is `CaseIterable`, so the
  Settings list and the polling flow pick them up for free).

### D.4 Exit gate

"volume to fifty percent" → one pass, no model, < 150 ms, verifiable read-back. "empty trash" →
confirmation sheet, and refusal if the user says no. "lock my screen" → locked. All of it with
Wi-Fi off.

---

## Phase E — Browser lane (zero-screenshot, element index)

**Goal:** row 4. Also the answer to "Electron apps expose nothing useful over AX".

### E.1 Order of preference

1. **CDP** for Chromium-family browsers (Chrome, Brave, Edge, Arc, and every Electron app that
   exposes a debug port): `http://127.0.0.1:<port>/json` → WebSocket → `Runtime.evaluate`.
   Opt-in per browser, clearly labelled, because it requires launching the browser with
   `--remote-debugging-port`.
2. **MV3 extension + native messaging** as the no-flags path: the extension walks the DOM,
   sends the same indexed payload over a Unix socket, and pp never sees a screenshot.
3. **AX** as the fallback (today's behaviour).
4. Ask.

`Sources/PpCore/AdapterProtocol.swift` already defines the adapter contract, capability manifest,
origin scoping and the conformance suite; this phase implements two conforming adapters and runs
the same suite over both.

### E.2 Index payload

Reuse the existing wire contract: the model picks an *index*, not a coordinate.

```
[#12 role=searchbox label="Search" in=viewport], [#15 role=button label="Documentation"]
```

- `Sources/PpDesktop/DOMIndexer.swift` builds it: only visible, only interactive, label from
  accessible name → placeholder → text content (truncated), plus `rect` for a later native click.
- Cap at `Shortlister.defaultLimit` (16) using the existing ranker with the learned priors, so a
  previously clicked "Documentation" link rises without any new machinery.
- Never include values of `type=password`, `autocomplete=cc-*`, or anything inside a payment
  iframe; assert this with a fixture in the conformance suite.

### E.3 Exit gate

On a recorded page: "click the documentation link" → correct index, no screenshot, < 400 ms,
and the same test passes for the extension adapter and the CDP adapter.

---

## Phase F — Novel skill synthesis, with the four gates

**Goal:** row 5, and the ability to grow without a release.

Overlaps Phase D by design: anything in the Phase D table never reaches synthesis. Synthesis is
for the long tail ("snap this window to the left half", "start a Pomodoro").

### F.1 Proposal

`Sources/PpCore/PlannerSeam.swift` already has the seam. Add
`Sources/PpMLXScriptProposer.swift` (or a `LocalServerScriptProposer` that talks to whatever the
user configured in Settings) with one method:

```swift
public protocol ScriptProposing: Sendable {
    func propose(goal: String, frontApp: String) async throws -> String  // AppleScript source
}
```

### F.2 The four gates (all blocking, in this order)

`Sources/PpCore/ScriptGates.swift` — pure where possible, one subprocess for the compiler:

| Gate | Rule | Failure mode it kills |
| :-- | :-- | :-- |
| 1. Compile | `osacompile -e <source> -o /tmp/x.scpt` must exit 0 | syntax hallucination |
| 2. Effect | source must match `keystroke|click|set volume|set value|tell application .* to (make|delete|set)` | empty stub that "succeeds" and does nothing |
| 3. Policy | blocklist: `/System`, `/Library`, `~/.ssh`, `.env`, `Keychain`, `Terminal`, `sudo`, `do shell script` with `rm`, `curl`, `chmod`, `launchctl`, `defaults delete`, `osascript` recursion | the whole class of demos that end with someone's home directory gone |
| 4. Verify | Laya `noul` question: P(script achieves goal) ≥ 0.4 | plausible-looking script that does the wrong thing |

Reject with a reason the user can read ("this script would run a shell command"). Never execute a
rejected script, and never silently fall back to a different script.

### F.3 Learned skills

`Sources/PpCore/LearnedSkills.swift` → `learned.json` in Application Support, same privacy rules as
`LearningRecorder` (`PrivacyFilter` on the way in, listed in the personalization panel, deletable
with everything else). Retrieval happens **before** synthesis and before the model, like macros:
"start a pomodoro" → seconds, no model call.

### F.4 Tests

Adversarial fixtures are the whole point: a script that reads `~/.ssh/id_rsa`, one that deletes
the Downloads folder, one that calls `do shell script "curl … | sh"`, one that is an empty `tell
application "Finder" to return`, one that opens Terminal, and a legitimate window-snap script
that must pass all four. Plus: a rejected script leaves no trace in `learned.json`.

### F.5 Exit gate

"toggle dark mode" must **not** reach synthesis (it is Phase D). Use "snap this window to the left
half": first attempt proposes, gates, runs, and caches; second attempt is instant and model-free;
the adversarial battery cannot make it run a shell command.

---

## Part IV — Cross-cutting

## Phase G — Safety and privacy invariants

Write these into `docs/` as the checklist a reviewer walks, and pin each with a test:

1. **Screen text is never an instruction.** Labels and page text are data. `SafetyCritic` already
   carries a `promptInjection` category; every new lane (system, time, script) must route through
   it, and the script lane must treat page text as hostile input to the proposer.
2. **Every outward effect gates.** Send/delete/purchase/permission changes, and now shell-adjacent
   AppleScript and trash-emptying. A learned macro or skill can never create permission.
3. **Partials only preempt the allowlist.** Lane 1 is launch/quit/open-URL and nothing else.
4. **Secure fields are opaque.** `PrivacyFilter` already drops credentials and one-time codes;
   the DOM indexer must add the browser-side equivalent.
5. **Everything is inspectable and deletable**: history, macros, priors, alarms, learned skills —
   all listed in `Settings → What pp has learned`, all removed by "Delete everything".
6. **No cloud in the default path**, and the microphone closes within one buffer on dismiss.

## Phase H — Measurement and the acceptance battery

### H.1 Instrumentation

`PpDesktopApp` already prints a `timing` line. Extend it to named marks:
`asr.partial → preempt.decide → preempt.act → asr.final → route → read → decide → act → verify`,
emitted as one `preempt:`/`timing:` log line with millisecond deltas. Everything in §3.2 can then
be confirmed or contradicted by `/usr/bin/log show --predicate 'subsystem == "local.pp"'`, which is
how the current numbers in this plan were obtained.

### H.2 The battery, as runnable tests

| Phase | Test | Assertion |
| :-- | :-- | :-- |
| 1 | `PreemptionTests.launchesWhileSpeaking` | with a scripted partial stream, the launch is dispatched before the final is delivered |
| 2 | `SystemIntentTests.volumeFifty` | parses to `.volume(.set(50))`, executes with no model call |
| 3 | `SubstringTests.searchText` | the typed string is byte-identical to the transcript slice |
| 4 | `DOMIndexerTests.documentationLink` | correct index on a recorded DOM, no screenshot API called |
| 5 | `ScriptGateTests.novelSkillThenCache` | runs once, cached, second run model-free |
| 6 | `AdversarialSafetyTests.terminalDelete` | refusal, zero AppleScript compiled or run |

Voice-driven versions of 1, 3, 4 and 7 need recorded WAVs and a fake `SpeechProvider` (both
already exist as seams: `Sources/PpCore/SpeechProvider.swift`, `FakeSpeechProvider`). Add
`fixtures/voice/` with four short clips and a `scripts/check-voice.sh` mirroring
`check-desktop.sh`.

### H.3 Regression ritual

Every real bug found after this ships gets a fixture: `(recorded partial stream or tree,
transcript, expected lane, expected action sequence)`. Replays in milliseconds, no UI, no audio,
no model weights.

## Phase I — Packaging, and what we are allowed to claim

- Entitlements: add `com.apple.security.automation.apple-events`; keep hardened runtime; app stays
  unsandboxed (Accessibility requires it).
- Info.plist: add `NSAppleEventsUsageDescription`, `NSCalendarsUsageDescription`,
  `NSRemindersUsageDescription`; keep the microphone and speech strings; drop nothing.
- Notarization: `scripts/sign-and-notarize.sh` already exists; extend it to verify the new
  entitlements with `codesign -d --entitlements`.
- Copy rules for the marketing page, because a benchmark is a promise:
  - quote **measured** numbers and say what machine they came from ("370 ms on an M3 Air"), never
    a round number from a demo of other software;
  - never claim app coverage we have not tested — the honest claim is "the apps in the accuracy
    suite", and that suite should be listed;
  - "offline after setup" is true; "no internet ever" is not, and saying it invites a screenshot
    of the model download;
  - alarms live in pp, not in Clock — say so on the page, not in a support thread.

---

## Part V — Sequence and decisions

### 5.1 Order of work

Ordered so the riskiest, most demo-critical thing lands first and each phase leaves the app
shippable.

| Phase | Days (one dev, part-time) | Depends on | Unlocks |
| :-- | :-- | :-- | :-- |
| A. Preemption | 3–5 | — | row 1, the whole pitch |
| B. Island + wake + "thank you" | 4–6 | — | rows 7–9, the feel |
| C. Time | 3–4 | B (to show alarms) | row 9, first "Siri can't do that fast" win |
| D. System commands | 4–6 | Safety critic | row 2, and half of the long tail |
| H. Harness (do it here, not last) | 2–3 | A, B | every later phase gets measured |
| E. Browser lane | 6–10 | D | row 4, Electron apps |
| F. Script synthesis | 8–12 | D, G | row 5, growth without releases |
| G. Invariants review | 1 | all | the right to ship |

Total to a demoable product: **A + B + C + H ≈ 2–3 weeks**. A + B alone is a week and is enough
to film the demo honestly.

### 5.2 Decisions to make before writing code

| # | Decision | Recommendation |
| :-- | :-- | :-- |
| 1 | Preempt on first stable partial, or wait for EOU | two identical partials; never the first |
| 2 | Preempt allowlist contents | launch, quit, open URL. Nothing else in v2.0 |
| 3 | Identity of the island | its own always-visible pill; never a menu-bar popover (focus theft) |
| 4 | Where alarms live | own store + notifications; Calendar only for "remind me" |
| 5 | System-action model | separate `SystemIntent` lane, not `PlanStep.Kind` |
| 6 | Browser lane | CDP first (no extension to install), extension second |
| 7 | Whisper wake | fuzzy phrase variants + lower EOU floor; no loudness gate |

### 5.3 Risks

| Risk | Impact | Mitigation |
| :-- | :-- | :-- |
| A misheard partial launches the wrong app | the demo's whole credibility | stability rule + allowlist + visible island + Escape |
| Speech recognition final lag (~200–500 ms) | row 1 slips past 500 ms | preempt hides it: the action starts before the final arrives |
| TCC prompts for Apple Events/Calendar | looks broken on first run | all prompts through `OnboardingCoordinator`, with the pane deep-linked |
| Notification permission denied | alarms silently never fire | check authorisation when the alarm is set, and say so at that moment |
| CDP requires a browser flag | "doesn't work with my browser" | extension path second, AX third, and say which lane was used |
| AppleScript surface shrinking on future macOS | Phase D rots | every action verified by read-back; a failed action reports, never pretends |
| Preempting two different apps in one sentence | two windows open | `.supersede` is deliberate; document, do not hide |
| Thermal load from a long session | latency creeps on a fanless Air | the model already runs per cycle, not continuously; measure with `powermetrics` in Phase H |

### 5.4 First day

1. Read `Sources/PpCore/DirectIntent.swift`, `Sources/PpDesktop/AppResolver.swift`, and
   `PpDesktopApp.runDirectIfReady` — the preemption path is a small extension of them.
2. Write `PreemptionPolicy` with its tests and nothing else. It is pure, so it is finished before
   lunch and it de-risks the whole demo.
3. Add `onPartial` to `SpeechInput` and log the partial stream while saying commands out loud.
   That log tells you the real stability numbers (`minimumStableObservations`) to use — do not
   guess them.
4. Only then wire it to `performDirect` and watch Notes arrive early.
