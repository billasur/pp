# pp v3 — "understand me, and stay listening"

Diagnosis and file-by-file plan, written 2026-09-23 against the tree at `9689b8f` plus the
uncommitted v2.1 changes. Nothing here is built yet.

Everything you reported is a real defect with a specific cause in the code. None of it needs a
new model, and only one item (a stronger speech recogniser) needs a download. The order below is
chosen so the cheap wins land first.

---

## 0. Do these three things before anything else

1. **Kill the double UI in ten seconds.** `defaults delete local.pp DebugHooks` then quit and
   relaunch pp. The second panel at the bottom of the screen is the debug voice widget, and
   `DebugHooks` is set to 1 in your defaults right now (`defaults read local.pp` shows
   `DebugHooks = 1`, plus a saved `NSWindow Frame DesktopVoiceWidget`). Track V5 removes the code
   path properly; this command proves the diagnosis immediately.
2. **Look at what pp hears while you talk.** Until you can see the transcript, every miss looks
   like the assistant being stupid rather than the recogniser mishearing. Track V2 adds a
   `heard:` line to the island and a terminal harness; do that early.
3. **Rebuild after every change.** `./build.sh` refuses while pp is running, so quit the app
   first. The installed app in `~/Applications/pp.app` is a release build of this source tree.

---

## 1. What you said, and what the code actually does

The assistant fails in three different layers, and they need different fixes. Hearing is the
speech recogniser. Understanding is the parsers and the model. Doing is the execution lanes.
Most of your list is *understanding* and *doing*, not the model.

| You said | What the code does | Why | Track |
| :-- | :-- | :-- | :-- |
| "hey pp" only works half the time | `WakePhrase` accepts an exact prefix plus four hard-coded variants (`WakePhrase.swift:27-64`). The recogniser is only hinted with the string `"Hey pp"` (`SpeechInput.swift:103`). | Apple's recogniser renders a two-letter word many ways: "hey pp", "hey p p", "a pp", "hey bee", "heipp", "hey papa", and sometimes as one token. Nothing matches those, and nothing else biases the recogniser toward your vocabulary. | V2 |
| wake, then the command is missed | On end of utterance the app requires the wake phrase to be inside that same final transcript; a bare "hey pp" restarts the whole recognition task (`PpDesktopApp.swift:352-380`, `beginSpeech` at `:850`). | Restarting `SFSpeechAudioBufferRecognitionRequest` throws away whatever you said during the restart. On-device recognition plus a task restart is where the first word of the command goes. There is also a hard 45-second session cap (`SpeechInput.swift:182-191`). | V1 |
| "open zen" needs spelling | `AppNameMatcher` is exact-or-unique-prefix only (`DirectIntent.swift:158-166`), and `contextualStrings` never includes app names. Zen is installed as `/Applications/Zen.app` with bundle name `Zen`, so *once the recogniser hears "zen"* resolution works. | This is a hearing problem, not an understanding problem. "then", "sin", "zenn" never reach the matcher. | V2 |
| "search youtube.com" opens a Google search | `GrammarPlanner.swift:95-100` turns every `search X` into `https://www.google.com/search?q=X` — including when X is a domain. | There is no web lane. Your sentence went: not a TimeIntent, not a DirectIntent (the verb is "search", not "open"), then the grammar planner, which built a Google URL for the literal text "youtube.com". | V3 |
| WhatsApp messages do nothing | Nothing exists. No messaging lane, no contact resolution, no WhatsApp adapter (`grep -rin whatsapp Sources` returns nothing). | Genuine missing feature. | V3 |
| alarms do not ring | `AlarmScheduler` adds a `UNNotificationRequest` and verifies it is *pending* (`AlarmScheduler.swift:44-52`, `:70-78`). No `UNUserNotificationCenterDelegate` is installed anywhere, the sound is `.defaultCritical` (`:35`, `:61`) which needs an entitlement you do not have, and the authorization result is discarded (`:19-27`). | Three separate reasons the alarm never rings: notifications are suppressed while the app is running without `willPresent`; a critical sound without the critical-alerts entitlement; and permission denied still reports "pending", so the app says "Alarm set" while nothing will ever fire. | V4 |
| the UI opens twice | `DebugHooks` is on, so `showOverlay` also builds the legacy 244×202 widget and orders it front (`PpDesktopApp.swift:2223-2244`), while the island shows at the same time. | Debug flag left on, plus a second code path that was supposed to be dev-only. | V5 |
| the top island is not where you want it | `IslandController.updatePanelFrame` centres the capsule on the visible frame (`IslandController.swift:96-112`). | No notion of the notch. It needs `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` and two panels, one each side. | V5 |

---

## 2. Track V1 — One wake, then a session that stays open

**Goal:** say "hey pp" once. pp keeps listening across pauses, executes each sentence as it
completes, and only closes the microphone when you say "bye" (or press Escape, or stop talking
for the idle timeout).

### Design

A session is a state machine, not a series of one-shot recognitions.

```
idle ──"hey pp"──► session ──clause complete──► execute, stay in session
                      │
                      ├──"bye" / Escape / 5 min silence ──► closing ──► idle
```

Rules:

- The wake phrase may appear anywhere in the first four words of a partial, so "okay hey pp" and
  "hey pp" both work.
- Inside a session the recognition task stays alive. When Apple ends a task after a final, the
  controller restarts it and **replays the last ~2 seconds of PCM** from a ring buffer, so the
  word being spoken at the boundary is not lost. This is the single most important fix for
  "it heard the wake and then missed the command".
- Each completed clause is executed immediately; the session does not close.
- Session ends on: a dismissal phrase (`bye`, `goodbye`, `that's all`, `thank you`, `stop
  listening`, `quiet`, `never mind`), Escape or the island's ✕, a microphone/permission failure,
  or `sessionIdleSeconds` (default 300) with no speech at all.
- Inside a session, end-of-utterance silence is longer (default 1.0 s) than the wake-phase
  (default 0.6 s), so a mid-sentence pause does not split a command in half.

### Files

| File | Change |
| :-- | :-- |
| `Sources/PpCore/WakeSession.swift` **(new)** | Pure state machine: `enum Phase { idle, wakeListening, session, closing }`, `mutating func ingest(partial:) -> WakeSessionOutcome`, `mutating func clauseCompleted(_ text:) -> SessionAction` (`.execute(String)`, `.close`, `.none`), `dismissal` handling, idle timing injected as a `TimeInterval` parameter so tests need no clock. No AppKit, no AVFoundation. |
| `Sources/PpCore/AudioRingBuffer.swift` **(new)** | Fixed-capacity PCM ring buffer (default 2 s at the input format), `append(_:)`, `snapshot()`, `clear()`. Used to replay audio across a recognition-task restart. |
| `Sources/PpDesktop/SpeechInput.swift` | Add `func startSession(vocabulary:)` and `func endSession(reason:)`. Keep the existing `start(handsFree:wakePhrase:)` for hold-to-talk so nothing else breaks. Session mode: no 45-second cap, restart-and-replay on task completion, `onClauseClosed` delivered to the app (it is currently defined at `:16` and never wired), and `onPartial` always delivered. |
| `Sources/PpDesktop/PpDesktopApp.swift` | Replace the `waitingForWake` boolean with the session from `WakeSession`. Wire `speech.onClauseClosed`. On a session clause: run it through the router exactly as a final is run today. On `.close`: hide the island, `speech.endSession()`, `wake.finishCommand()`. |
| `Sources/PpCore/DismissalPhrase.swift` | Confirm the full closing set is present: `bye`, `goodbye`, `bye bye`, `that's all`, `thank you`, `stop listening`, `quiet`, `never mind`, plus the existing `stop`/`cancel`. Keep the negatives ("stop the music" is a command). |
| `Sources/PpDesktop/EnergyEOU.swift` | Two configs: `wakePhase` and `sessionPhase`, the second with a longer silence window and the existing `whisperCeilingDbfs`. |
| `Tests/PpCoreTests/WakeSessionTests.swift` **(new)** | Wake anywhere in the first four words; a bare "hey pp" then a command two seconds later stays in session; three clauses in one session execute in order; "bye" closes; idle timeout closes; "stop the music" does not close; Escape closes. |
| `Tests/DesktopChecks/main.swift` | A scripted partial stream: wake, pause, three clauses, dismissal — assert three executions and one close, with no audio hardware. |

### Acceptance

Say: "hey pp" … (5 s pause) "open zen" … (pause) "open youtube.com" … (pause) "search youtube
for lofi beats" … "bye". Three commands execute, the microphone closes on "bye", and the log
shows one wake and one session.

**Cost: 1–2 days.** This is the highest-value track in the document.

---

## 3. Track V2 — Being understood (hearing)

**Goal:** "hey pp", "open zen", "whatsapp Diya", "set an alarm for seven thirty" arrive as text
that the parsers can act on, and when they do not, you can see why.

### Files

| File | Change |
| :-- | :-- |
| `Sources/PpCore/SpeechVocabulary.swift` **(new)** | Builds the `contextualStrings` array handed to the recogniser: wake variants; every installed app name and file name (from the same scan `AppResolver` already does); aliases; site names (youtube, google, github, wikipedia, whatsapp, spotify, maps, reddit, x, chatgpt); your frequent contacts from `RankingFeatures.frequentContacts`; and the verbs pp understands ("set an alarm", "message", "search for", "open", "quit"). Cap the list (aim 60–120 entries): a giant list helps less than a tight, relevant one. Refresh it when apps or contacts change. |
| `Sources/PpCore/WakeMatcher.swift` **(new)** | Replaces the ad-hoc variant checks in `WakePhrase`. Normalise (lowercase, strip punctuation, collapse doubled letters), then match against a small candidate set per word — `hey/hei/he/ey/a/hay`, `pp/p p/pee pee/peep/peepy/pip/pop/papa` — allowing one edit distance on the second word, accepting single-token merges (`heypp`, `heipp`, `aip`, `heypee`), and returning the matched range so the remainder is sliced byte-for-byte. Phrase must be in the first four tokens. |
| `Sources/PpCore/AppAliases.swift` **(new)** | Built-in aliases: `zen`→Zen, `chrome`→Google Chrome, `code`/`vs code`→Visual Studio Code, `whatsapp`→WhatsApp, `messages`→Messages, `terminal`→Terminal, `notes`→Notes, `finder`, `safari`, `photos`, `music`, `calendar`, `mail`→Mail. User aliases persisted through `PersonalizationStore` and editable in Settings, so "my browser" can mean Zen. |
| `Sources/PpCore/DirectIntent.swift` | `AppNameMatcher.match` gains (a) alias resolution, (b) safe fuzzy matching — edit distance ≤1, only for names of four or more characters, only when exactly one candidate wins, (c) spelled-out input: a run of single-letter tokens (`z e n`, `s a f a r i`) collapses to a word before matching. Keep exact and prefix rules first so nothing regresses. |
| `Sources/PpDesktop/SpeechInput.swift` | `contextualStrings = SpeechVocabulary.shared.commandStrings()` instead of `[wakePhrase]`; `request.addsPunctuation = false`; keep `shouldReportPartialResults = true`. |
| `Sources/PpCore/RecognitionSettings.swift` **(new)** | One setting with honest copy: `onDevice` (default, private, less accurate on short words) and `preferAppleServers` (more accurate, audio leaves the Mac for Apple's recogniser — the Info.plist string already discloses this). Surfaced in Settings; the island shows which mode is active. |
| `Sources/PpDesktop/IslandView.swift` | In `.listening`, show a second line with the live transcript (`heard: open then`). This is a debugging tool and a trust feature at the same time. |
| `Sources/PpDesktop/PpDesktopApp.swift` | Pass the vocabulary into the session; add the transcript line to the island state; add a menu item "Copy last transcript" so you can send me the exact mishears. |
| `scripts/hear.sh` + `--hear` flag in `PpDesktopApp` | Prints recognised partials with timestamps to the terminal. Faster than watching the island while you talk. |
| `fixtures/asr_phrases.jsonl` **(new)** | The phrases that failed, with the expected command: "hey pp open zen", "ey pp open zen", "heipp open zen", "open then", "search youtube.com", "set an alarm for seven thirty", "whatsapp diya". Used by the matcher tests and later by a real-ASR harness. |
| `Tests/PpCoreTests/WakeMatcherTests.swift` **(new)** | 40+ strings including every failure mode above, plus negatives ("hey buddy", "open pp", "heyyy"). |
| `Tests/PpCoreTests/AppAliasTests.swift` **(new)** | Aliases, spelled letters, fuzzy acceptance, and the rule that ambiguity resolves to nothing rather than to a guess. |

**Note on honesty:** vocab bias and fuzzy matching reduce mishears; they do not eliminate them.
If "zen" and "hey pp" are still unreliable after this track, the next step is a stronger local
recogniser (Parakeet TDT v3 / Whisper via FluidAudio) and a dedicated wake-word model
(sherpa-onnx KWS). Both are downloads behind existing seams (`SpeechProvider`), not rewrites —
see §9.

**Cost: 1–1.5 days plus one listening session of real testing.**

---

## 4. Track V3 — Doing the things you asked for

Three new capabilities, in the order that removes the most frustration.

### V3.1 Web lane (fixes "search youtube.com")

| File | Change |
| :-- | :-- |
| `Sources/PpCore/SiteTable.swift` **(new)** | Known sites with search URL templates and a canonical host: youtube (`https://www.youtube.com/results?search_query={q}`), google, github, wikipedia, maps, amazon, reddit, stackoverflow, x, spotify, linkedin, chatgpt, perplexity. |
| `Sources/PpCore/WebIntent.swift` **(new)** | `enum WebIntent { case openSite(host: String), search(query: String, site: String?), play(query: String, site: String), none }`. Rules, each a test: (a) `open|go to|visit <domain>` → `openSite`; (b) `search <site> for <query>` → `search(site:)`; (c) `search <domain>` where the argument is a bare domain → `openSite` — this is your exact sentence, "search youtube.com"; (d) `search for <query>` / `google <query>` → `search(site: preferred)`; (e) `play <query> on youtube` → `play`; (f) a bare domain with no verb → `openSite`. |
| `Sources/PpCore/GrammarPlanner.swift` | Stop building Google URLs here (`:95-100`). Delegate to `WebIntent`; if `WebIntent` returns `.none`, keep the existing behaviour as a fallback so nothing regresses. |
| `Sources/PpCore/Preferences.swift` **(new)** | `preferredBrowser` (default: system default; override to a specific app so "open youtube.com" always lands in Zen) and `preferredSearchEngine` (default Google). |
| `Sources/PpDesktop/Desktop.swift` | `open(website:browser:)` already accepts a browser URL (`:1355-1363`); pass the preferred browser through and include the browser name in the spoken confirmation ("Opened youtube.com in Zen"). |
| `Tests/PpCoreTests/WebIntentTests.swift` **(new)** | 30 cases across the six rules, including "search youtube.com" → open, "search youtube for lofi" → youtube results, "open youtube.com" → open, "play lofi on youtube" → results, and the negative "search my email for the invoice" → `.none` (that is a screen task, not a web task). |

### V3.2 Messaging lane (fixes WhatsApp)

| File | Change |
| :-- | :-- |
| `Sources/PpCore/MessageIntent.swift` **(new)** | `enum MessageIntent { case send(app: MessagingApp, contact: String, text: String), none }`. Parses "message Diya on whatsapp saying the launch is tomorrow", "whatsapp Diya the launch is tomorrow", "send Diya a message on whatsapp: …", "text Diya …" (Messages). Anything without both a contact and a body is `.none` and asks for the missing half. |
| `Sources/PpCore/ContactsResolver.swift` **(new)** | Spoken name → contact via the Contacts framework, with the app's own search box as a fallback. Returns every candidate so an ambiguous name asks instead of guessing. Needs `NSContactsUsageDescription` in `Resources/Info.plist` and a TCC prompt through `OnboardingCoordinator`. |
| `Sources/PpDesktop/MessagesAdapter.swift` **(new)** | The robust sibling: Messages.app has an AppleScript dictionary, so `tell application "Messages" to send "text" to buddy "…"` works and is testable. Use it for iMessage/SMS. |
| `Sources/PpDesktop/WhatsAppAdapter.swift` **(new)** | The fragile one, done carefully: activate WhatsApp → focus its search field (AX) → type the contact → wait for rows with a timeout → pick the exact match, or the first row if the user confirms → focus the message field → insert the text (never keystroke per character; set the AX value once) → **stop and ask**. Send only on "send it" (spoken) or ⌘↩. |
| `Sources/PpCore/SafetyCritic.swift` | Confirm `outwardTransmission` is returned for messaging (`send`, `message`, `whatsapp`) and that the adapter cannot bypass it. |
| `Sources/PpDesktop/PpDesktopApp.swift` | Route `MessageIntent` after `WebIntent` and before the model; the confirmation state shows the resolved contact and the exact text in the island, and the send action is the only path to the adapter's `send()`. Record `frequentContacts` on success, redacted text in `EventLog`. |
| `Tests/PpCoreTests/MessageIntentTests.swift` **(new)**, `Tests/PpCoreTests/ContactsResolverTests.swift` **(new)** | Parse table; ambiguous contact asks; missing body asks; an unknown contact never sends; a fixture recorded from WhatsApp's AX tree drives the adapter in replay with a `RecordingRunner`. |
| `Tests/PpCoreTests/AdversarialSafetyTests.swift` | Add: a message intent can never reach the send step without an explicit confirmation; a contact name taken from on-screen text is not trusted as the destination. |

### V3.3 Router order, written down and tested

```
dismissal → session/wake → TimeIntent → WebIntent → MessageIntent →
SystemIntent → DirectIntent (app/quit/site) → GrammarPlanner → model
```

`Sources/PpCore/CommandRouter.swift` **(new)**: one pure function
`route(text:) -> CommandRoute` that names the lane and the parsed intent, with no side effects.
The app executes the route. `Tests/PpCoreTests/CommandRouterTests.swift` asserts the lane for
every sentence in `fixtures/acceptance.jsonl`, which makes "it picked the wrong lane" a failing
unit test instead of a mystery in the moment.

**Cost: WebIntent half a day, router half a day, WhatsApp 2–3 days.**

---

## 5. Track V4 — Alarms that actually ring

| File | Change |
| :-- | :-- |
| `Sources/PpDesktop/NotificationCenter.swift` **(new)** | Installs `UNUserNotificationCenter.current().delegate` at launch. `willPresent` returns `[.banner, .sound, .list]` so the alarm is presented **while pp is running** (today it is suppressed, which alone explains "nothing happens"). `didReceive` handles the `STOP` and `SNOOZE` actions. |
| `Sources/PpDesktop/AlarmScheduler.swift` | Replace `.defaultCritical` with `.default` or a bundled `UNNotificationSound(named: "Alarm.caf")` — critical alerts need `com.apple.developer.usernotifications.critical-alerts` and you do not have it; without it the request can be refused or delivered silently. Check the authorization result and surface it: "Notifications are turned off for pp; this alarm will not ring. Open Settings?" — and do **not** claim the alarm is set. Read-back must check *authorization and* the pending request, because a pending request for a denied app is not an alarm. |
| `Sources/PpCore/NotificationScheduling.swift` **(new)** | A small protocol (`requestAuthorization`, `add`, `pending`, `remove`) so `AlarmScheduler` can be faked in tests. `UNUserNotificationCenter` conforms in the app target. |
| `Sources/PpDesktop/PpDesktopApp.swift` | In-app ringer: an alarm that fires while pp runs also plays a looping `NSSound`, shows the island in a new `.alarm` state with a Stop button, and accepts "stop" / "quiet" by voice. Wire ⌘-click on the island's Stop to the same path. |
| `Sources/PpCore/AlarmStore.swift` | Mark items fired, prune past non-repeating items on launch, expose `nextFireDate` so the island can show "next alarm in 6 h". |
| `Sources/PpCore/TimeIntent.swift` | Fill the gaps: "wake me at 6:30", "at 7" (no "alarm" word), "in twenty minutes" / "twenty minutes from now" (timer), "tomorrow at 7", "7 15" and "715" (digits without a colon), "quiet the alarm", "snooze", "cancel my alarm" (all alarms), "what is my next alarm". Keep the media negatives. |
| `Resources/Info.plist` | Add `NSContactsUsageDescription` (needed by V3.2). Notification permission needs no plist key. |
| `Tests/PpCoreTests/TimeIntentTests.swift` | 20 more cases for the phrases above. |
| `Tests/PpCoreTests/AlarmSchedulerTests.swift` | Against the fake scheduler: authorization denied → an error result, never "set"; pending but unauthorized → error; happy path → verified; cancel removes. |

**Acceptance:** set an alarm two minutes out, quit pp, hear it ring; set one while pp is running
and see the island ring with a Stop that works; deny notifications and confirm pp *says* the
alarm will not ring instead of pretending.

**Cost: 2–3 hours for the ring itself, half a day with the in-app ringer and tests.**

---

## 6. Track V5 — The island: one window, split around the notch

**Goal:** exactly two capsules, left and right of the notch, nothing anywhere else on screen.

| File | Change |
| :-- | :-- |
| `Sources/PpDesktop/PpDesktopApp.swift:2223-2244` | Delete the debug widget block outright, not just conditionally. Remove the `DebugHooks` read in `showOverlay`, remove the `overlay` panel property, and delete `VoiceWidget` (or move it out of the shipping target). Also `defaults delete local.pp DebugHooks` and remove the saved frame: `defaults delete local.pp "NSWindow Frame DesktopVoiceWidget"`. |
| `Sources/PpDesktop/NotchLayout.swift` **(new)** | Pure geometry: given a struct `ScreenGeometry { fullFrame, visibleFrame, safeAreaInsets, auxTopLeft, auxTopRight, hasNotch }`, return the two usable bands and the menu-bar height. Uses `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` when present (macOS 12+, and your 13.6″ Air has the notch), and falls back to the two halves of the menu-bar strip on a notchless display. Pure means it is unit-testable without a second monitor. |
| `Sources/PpDesktop/IslandController.swift` | Two panels. `leftPanel`: state indicator (idle dot / level meter / alarm bell) plus the ✕ cancel button. `rightPanel`: the headline and, while listening, the `heard:` transcript line. Both sized to their band with an 8 pt inset, vertically centred in the menu-bar strip, `NSPanel` with `.nonactivatingPanel`, `level = .statusBar`, `[.canJoinAllSpaces, .fullScreenAuxiliary]`, `hidesOnDeactivate = false`, never key. `hide()` orders both out. Replace the centre-the-visible-frame maths (`IslandController.swift:96-112`). |
| `Sources/PpCore/IslandState.swift` | Add `.alarm` (ringing, with a stop affordance) and `.heard(String)` (live transcript). Keep `size` derived from the band width instead of fixed numbers, and keep `autoHideDuration` (result 2.5 s, error 6 s, alarm never). |
| `Tests/PpCoreTests/NotchLayoutTests.swift` **(new)** | A notched geometry and a notchless one; both bands inside the frame; no overlap with the notch; correct fallback. `IslandStateTests` gains the alarm and heard cases. |

**Acceptance:** wake pp and see exactly two capsules flanking the notch; nothing at the bottom of
the screen; quitting and relaunching does not resurrect the old panel; on an external display
the capsules split into the two halves of the menu bar instead of hiding under the notch.

**Cost: half a day, plus an hour of pixel-fiddling on the real display.**

---

## 7. Track V6 — A battery you can run every time

| File | Change |
| :-- | :-- |
| `fixtures/acceptance.jsonl` **(new)** | ~40 sentences with the expected lane, steps and URL: everything you actually say, including the failures in this document. |
| `Sources/PpCore/CommandRouter.swift` | As in V3.3 — the router the fixture asserts against. |
| `Tests/PpCoreTests/AcceptanceTests.swift` **(new)** | Reads the fixture, asserts lane + intent for every line, no model, no audio, milliseconds. |
| `scripts/acceptance.sh` **(new)** | `swift test --filter AcceptanceTests` plus `check-desktop.sh`, `check-voice.sh`, and a printed pass/fail table. This is the command to run before every build you install. |
| `docs/BENCHMARKS.md` | Add the numbers that matter after V1: wake-to-first-action, and time from the last word of a clause to the action, measured with `Timing` (`timing.jsonl`), each labelled with the machine. |
| `docs/V3_MANUAL_BATTERY.md` **(new)** | The twelve things that need real apps, as a checklist with pass/fail boxes: wake by whisper, wake mid-room, three commands in one session, "bye" closes, Zen by name, Zen with an alias, youtube search, youtube.com open, WhatsApp send with confirmation, alarm rings with pp quit, alarm rings with pp open, two capsules around the notch. |

**Cost: half a day.**

---

## 8. Execution order for an agent (Antigravity prompt pack)

Work in `/Users/billasur/pp`. After **every** task: `swift build`, `swift test`,
`bash scripts/check-desktop.sh`, `bash scripts/check-voice.sh`. Never weaken `SafetyCritic` or
the privacy tests. Do not add third-party dependencies. Keep changes inside the files listed.
Do not commit unless asked.

| # | Task | Files | Est. | Depends on |
| :-- | :-- | :-- | :-- | :-- |
| 1 | Delete the debug widget path; leave one island | `PpDesktopApp.swift` | 30 min | — |
| 2 | Notification delegate, sound, permission surfacing | `NotificationCenter.swift` (new), `AlarmScheduler.swift`, `NotificationScheduling.swift` (new) | 3 h | — |
| 3 | WakeSession + ring buffer + session wiring | `WakeSession.swift`, `AudioRingBuffer.swift` (new), `SpeechInput.swift`, `PpDesktopApp.swift`, `EnergyEOU.swift`, `DismissalPhrase.swift` | 1–2 d | 1 |
| 4 | Vocabulary, WakeMatcher, aliases, fuzzy app match, transcript echo | `SpeechVocabulary.swift`, `WakeMatcher.swift`, `AppAliases.swift`, `RecognitionSettings.swift` (new), `DirectIntent.swift`, `SpeechInput.swift`, `IslandView.swift` | 1–1.5 d | 3 |
| 5 | Web lane + preferences | `SiteTable.swift`, `WebIntent.swift`, `Preferences.swift` (new), `GrammarPlanner.swift`, `Desktop.swift` | 0.5 d | 4 |
| 6 | Router + acceptance fixture + tests | `CommandRouter.swift` (new), `fixtures/acceptance.jsonl`, `AcceptanceTests.swift` | 0.5 d | 5 |
| 7 | Time gaps + in-app ringer + alarm island state | `TimeIntent.swift`, `AlarmStore.swift`, `IslandState.swift`, `PpDesktopApp.swift` | 0.5 d | 2 |
| 8 | Notch-aware split island | `NotchLayout.swift` (new), `IslandController.swift`, `IslandView.swift`, `IslandState.swift` | 0.5 d | 1 |
| 9 | Messaging lane (Messages first, then WhatsApp) | `MessageIntent.swift`, `ContactsResolver.swift`, `MessagesAdapter.swift`, `WhatsAppAdapter.swift` (new), `PpDesktopApp.swift`, `Info.plist` | 2–3 d | 6 |

**Prompt 1 — one island.** "In `Sources/PpDesktop/PpDesktopApp.swift`, delete the debug voice
widget block inside `showOverlay` (the `let debugHooks = …` branch that builds a 244×202
`NSPanel` with a `VoiceWidget`), delete the `overlay` property and every `overlay?` call, and
delete the `VoiceWidget` view. Keep `islandController` as the only UI surface, and keep
`showVoiceWidget()` working by routing it to the island. Remove the `DebugHooks` read. Run
`swift build && swift test`."

**Prompt 2 — alarms ring.** "Add `Sources/PpDesktop/NotificationCenter.swift` that sets
`UNUserNotificationCenter.current().delegate` at launch and implements `willPresent` (return
`[.banner, .sound, .list]`) and `didReceive` (handle `STOP`/`SNOOZE`). In
`AlarmScheduler.swift`, replace `.defaultCritical` with `.default`, check and surface the
authorization result, and make the read-back require both authorization and a pending request.
Add a `NotificationScheduling` protocol in `Sources/PpCore/NotificationScheduling.swift` and
make `AlarmScheduler` take it as a dependency so tests can fake it. Add
`Tests/PpCoreTests/AlarmSchedulerTests.swift` covering denied authorization, pending-but-denied,
and the happy path."

**Prompt 3 — one wake, one session.** "Add `Sources/PpCore/WakeSession.swift` (pure state
machine: wake → session → closing, dismissal phrases end the session, injectable clock) and
`Sources/PpCore/AudioRingBuffer.swift`. In `SpeechInput.swift`, add `startSession(vocabulary:)`
and `endSession(reason:)`: no 45-second cap, keep partials flowing, and on recognition-task
completion restart the task and replay the ring buffer so no speech is lost. Wire `onClauseClosed`
in `PpDesktopApp.swift` and route each completed clause through the existing command path while
the session stays open. Add `Tests/PpCoreTests/WakeSessionTests.swift` and a scripted partial
stream in `Tests/DesktopChecks/main.swift`. Acceptance: one 'hey pp', three clauses across
pauses, 'bye' closes the microphone."

**Prompt 4 — hearing.** "Add `Sources/PpCore/SpeechVocabulary.swift` (installed apps, aliases,
site names, frequent contacts, wake variants), `Sources/PpCore/WakeMatcher.swift` (normalise,
collapse doubled letters, candidate sets, one-edit tolerance, single-token merges like 'heipp',
match anywhere in the first four tokens, return the matched range), `Sources/PpCore/AppAliases.swift`,
and `Sources/PpCore/RecognitionSettings.swift`. Update `SpeechInput.swift` to use
`contextualStrings = SpeechVocabulary.shared.commandStrings()` and `addsPunctuation = false`.
Extend `AppNameMatcher` with aliases, safe one-edit fuzzy matching for names ≥4 characters, and
collapse of spelled-out single letters ('z e n' → 'zen'). Show the live transcript in
`IslandView` while listening. Tests: `WakeMatcherTests` (40+ strings) and `AppAliasTests`."

**Prompt 5 — web.** "Add `Sources/PpCore/SiteTable.swift`, `Sources/PpCore/WebIntent.swift` and
`Sources/PpCore/Preferences.swift`. `WebIntent` handles: `open <domain>`; `search <site> for <q>`;
`search <domain>` → open the domain (this is the fix for 'search youtube.com'); `search for <q>`
and `google <q>` → preferred engine; `play <q> on youtube`; a bare domain → open. Remove URL
construction from `GrammarPlanner` and delegate to it. Pass the preferred browser to
`Desktop.open(website:browser:)`. Tests: `WebIntentTests` (30 cases)."

**Prompt 6 — router and battery.** "Add `Sources/PpCore/CommandRouter.swift`, a pure function
`route(text:) -> CommandRoute` implementing the order: dismissal → session → TimeIntent →
WebIntent → MessageIntent → SystemIntent → DirectIntent → GrammarPlanner → model. Add
`fixtures/acceptance.jsonl` with ~40 sentences (expected lane + steps) and
`Tests/PpCoreTests/AcceptanceTests.swift` asserting them. Add `scripts/acceptance.sh` that runs
the test suites and prints a pass/fail table."

**Prompt 7 — alarms, gaps.** "Extend `TimeIntent` to parse 'wake me at 6:30', 'at 7', 'in
twenty minutes', 'tomorrow at 7', '7 15', 'quiet the alarm', 'snooze', 'cancel my alarm',
'what is my next alarm'. Add the in-app ringer: a new `.alarm` case in `IslandState`, a looping
`NSSound` and a Stop button in `PpDesktopApp`, and voice 'stop'/'quiet' handling. Add 20 cases to
`TimeIntentTests`."

**Prompt 8 — the island.** "Add `Sources/PpDesktop/NotchLayout.swift` (pure geometry returning
the left and right bands from `NSScreen.auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, with a
notchless fallback). Rewrite `IslandController` to own two panels — left: state + cancel; right:
headline + `heard:` transcript — each sized to its band with an 8 pt inset, vertically centred in
the menu-bar strip, never key, all spaces, hidden together. Add `NotchLayoutTests`."

**Prompt 9 — messaging.** "Add `Sources/PpCore/MessageIntent.swift`,
`Sources/PpCore/ContactsResolver.swift`, `Sources/PpDesktop/MessagesAdapter.swift` (AppleScript
to Messages) and `Sources/PpDesktop/WhatsAppAdapter.swift` (Accessibility: search field → contact
→ message field → confirm → send). Route `MessageIntent` in `CommandRouter` after WebIntent.
Sending requires an explicit spoken 'send it' or ⌘↩ after the island shows the resolved contact
and the exact text. Add `NSContactsUsageDescription` to `Resources/Info.plist`. Tests:
`MessageIntentTests`, `ContactsResolverTests`, a replayed WhatsApp AX fixture, and an adversarial
case proving an unknown contact cannot send."

---

## 9. Honest limits, and what to do if the fixes are not enough

- **Apple's on-device recogniser has a floor.** Short words in a quiet voice will still be
  misheard sometimes, and the fix above reduces the rate rather than zeroing it. If it is still
  not good enough, install a stronger local recogniser behind the existing `SpeechProvider`
  seam — Parakeet TDT v3 (batch, ~600 MB) or Whisper via FluidAudio, both already listed in the
  model plan. That is a download and an adapter, not a rewrite.
- **A phrase-based wake word is inherently weaker than a trained wake model.** sherpa-onnx KWS
  (~10 MB, open vocabulary) detects "hey pp" from acoustics rather than from a transcript, which
  is why it survives mishears. Adding it later behind the same seam is a day, and it is the
  honest answer if "hey pp" keeps failing.
- **The model was never the problem here.** Nothing in your list of failures was a decision-model
  failure; the Laya port is fine. Do not spend time on it before V1–V3 land.
- **WhatsApp accessibility trees change between releases.** Budget an hour whenever WhatsApp
  updates. Messages.app via AppleScript is the stable sibling, so iMessage works even when
  WhatsApp breaks.
- **Nothing in this plan needs the network**, and none of it touches the safety model: messaging
  keeps the outward-transmission gate, and no new lane can send anything without confirmation.

## 10. Definition of done

1. Say "hey pp" in a normal voice, once. It opens the session at least 9 times out of 10.
2. Speak three commands with pauses in between. All three run. Say "bye". The microphone closes.
3. "open zen" opens Zen without spelling it.
4. "search youtube.com" opens YouTube; "search youtube for lofi beats" opens YouTube results;
   "open youtube.com" opens it in your preferred browser.
5. "message Diya on whatsapp saying the launch is tomorrow" resolves Diya, shows the text, and
   sends only after you confirm.
6. "set an alarm for seven thirty" rings at 7:30, with pp quit, and says so honestly if the
   permission is missing.
7. Two capsules appear, one each side of the notch, and nothing else appears anywhere.
8. `bash scripts/acceptance.sh` passes, and every sentence in `fixtures/acceptance.jsonl` takes
   the lane the file says it should.
