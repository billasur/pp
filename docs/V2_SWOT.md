# pp v2 — SWOT

Written 2026-09-23, checked against the working tree rather than against the walkthrough.

Evidence used: `swift build` clean; `swift test` 182 tests, 0 failures, 0.30 s; `bash
scripts/check-desktop.sh` and `bash scripts/check-voice.sh` both pass; `PpDesktopApp.swift`
really does wire `PreemptionPolicy` (`:259`), `IslandController` (`:139`), `DismissalPhrase`
(`:347`) and `SystemActionParser` (`:399`); the v2 work is uncommitted on top of `3cdefab v1
baseline complete`.

The walkthrough is accurate about what was created. It is optimistic about three things, and
one of those three is a product-level problem rather than a code-level one.

## Claims against the tree

| Walkthrough claim | What the tree shows | Verdict |
| :-- | :-- | :-- |
| Preemption implemented and wired | `PreemptionPolicy.swift` (172 lines), called from `PpDesktopApp.swift:259`, reset per session at `:764` and `:1923` | true |
| Cooldown gap prevents repeated launches | The supersede block at `PreemptionPolicy.swift:80` returns on every path, so the cooldown check at `:96` is unreachable | **false** |
| `takeRemainder` never returns a mangled string | It never mangles, but it slices the *normalised* string (`PreemptionPolicy.swift:128-172`), so the remainder is lowercased and stripped of punctuation | true, and lossy |
| Island replaces the widget | `IslandController.show` runs, and the legacy 244×202 `VoiceWidget` `NSPanel` is still created and ordered front (`PpDesktopApp.swift:2000-2035`) | **false — two overlapping windows** |
| "Thank you" closes it | `DismissalPhrase.swift` + 8 cases, including "stop the music" and "cancel my subscription" negatives; wired at `PpDesktopApp.swift:347` | true |
| Whispered wake | `WakePhrase` quiet variants + `whisperCeilingDbfs = -24.0` in `EnergyEOU` | partial: no measured false-trigger data, and bare "pp" is accepted |
| Phase C — alarms and timers | `SystemActionParser.parseAlarm` computes an AM/PM heuristic, then `Desktop.executeSystemAction` *activates Clock.app* and returns "Alarm set for 7:00 PM." Nothing is scheduled, stored, or fired (`Desktop.swift:1448-1459`) | **false — the confirmation is fabricated** |
| Phase D — system actions | Five parsers (alarm, timer, volume, dark mode, lock, screenshot) of the thirteen in the plan. Lock is `pmset displaysleepnow`, which sleeps the display rather than locking. No read-back (`Desktop.swift:1460-1486`) | partial |
| Phase D — browser lane | `DOMIndexer.swift` is pure and tested, and is referenced by nothing outside its own test file | **false — no transport, not called** |
| Phase F — four gates | Four gates exist and are tested, but there is no proposer, gate 4 defaults to `probability: 1.0` so `evaluateAll(source:)` always passes it, and no `learned.json` cache exists | partial |
| Phase H — measurement | Three marks: partial, supersede, remainder. The plan asked for route, read, decide, act and verify too. `Tests/VoiceChecks/main.swift:33` prints milliseconds that were typed by hand | partial, with one fabricated line |
| Safety review doc, Info.plist keys | `docs/PP_V2_SAFETY_REVIEW.md` (38 lines); all three plist strings present | true |
| Cloud call sites gone | `Planner.swift:169` mentions OpenRouter in a doc comment only; the remaining network path is the user's own endpoint, off by default | true |

## Strengths

1. **The preemption seam is architecturally right.** A pure policy object with no AppKit, a
   clear allowlist, and a `.supersede` case for mid-sentence corrections. This is the part that
   no competitor ships and the part the demo actually needs. It is also the cheapest thing in
   the codebase to test, which is why it has 9 tests and a scripted transcript harness.
2. **Lane discipline is real.** `performDirect` (`:933`) resolves a name and calls the system
   with no screen read, and it is gated by `SafetyCritic` before every action. The 3.1 s Safari
   capture is genuinely skipped when the words name the target.
3. **Four deterministic lanes now exist in front of the model**: `DirectIntent`, system
   actions, dismissals, and grammar planning. Everything the model does not have to be asked
   about is a latency win and a hallucination surface removed.
4. **The safety work is not decorative.** Five risk categories, an adversarial suite, a
   privacy filter, and a script policy gate with tests. `AdversarialSafetyTests` and
   `PrivacyFilterTests` are the two files a reviewer should read first.
5. **Verification habits are in place.** 182 fast tests, two standalone harnesses that run
   without a UI, a fixture-parity suite against the Python oracle, and a benchmarks doc with
   measured numbers. This is unusual and it is what makes the next two months cheap.
6. **The bring-your-own-model story already works**: `ModelSources` accepts a folder, a
   `file://` URL, or an HTTP host, `BYOMPackageValidator` checks the contract before
   activation, and `Settings → Custom API` takes a URL plus key. Nothing to build.
7. **Learning is deterministic rather than statistical.** `LearningRecorder`, `MacroMiner`,
   `RankingFeatures`, `PersonalizationStore`: cheap, inspectable, deletable, and incapable of
   bypassing a gate.

## Weaknesses

1. **Alarms lie to the user (critical).** `Desktop.swift:1450-1459` opens Clock.app and returns
   "Alarm set for 7:00 PM." There is no `AlarmStore`, no `AlarmScheduler`, no
   `UNUserNotificationCenter` anywhere in `Sources`. Contract row 9 is unmet, and worse, the app
   says otherwise. This is the single highest-priority fix in the document.
2. **The remainder is lowercased.** `takeRemainder` normalises both sides
   (`PreemptionPolicy.swift:129-131`) and returns the normalised slice, so "open notes and write
   Sumit's number" types `sumit's number`. Contract row 3 asks for a byte-identical slice.
3. **Two windows on screen.** `PpDesktopApp.swift:2019-2034` still builds and orders front the
   old widget panel, on top of the island. The demo will show both.
4. **The preemption cooldown is dead code**, and `observationCounts` never decays, so the
   stability threshold is evaluated against counts accumulated across the whole session.
5. **System actions bypass the safety critic.** Both call sites (`:399`, `:831`) parse and
   execute. Only `performDirect` gates. Harmless for volume and dark mode, and not harmless the
   day "empty trash" or "send" arrives.
6. **The browser lane is a library with no caller.** No CDP client, no extension, no native
   messaging bridge. Contract row 4 is unmet.
7. **Script gate 3 is bypassable by string concatenation.** It substring-matches raw source, so
   `set p to "/Us" & "er/bin"` walks past it, and `do shell script` with decoded base64 walks
   past a denylist built of common tools. Gate 4's `probability: 1.0` default means the
   verification gate never runs unless a caller supplies a number.
8. **No system-action read-back.** Volume, dark mode and lock report success without checking.
   The plan's rule was "verifiable results, not 'done'".
9. **Measurement is partly fiction.** `Tests/VoiceChecks/main.swift:33` prints
   "preempt.decide (2ms) -> preempt.act (180ms)" as a constant. A harness that prints numbers
   nobody measured is worse than no harness, because it will be quoted.
10. **The harnesses compile copies of the sources** (`scripts/check-voice.sh`), so the same
    logic exists in two builds and can drift. `DOMIndexer` and the island are not covered by any
    harness.
11. **Island behaviour is untested.** `IslandState.size` and `autoHideDuration` are pure data
    and would take ten lines of tests; nothing asserts them today.
12. **Wake-word risk is unmeasured and the trigger is loose.** Bare "pp" is accepted. The plan's
    bar was two hours of room audio with zero wakes and that number does not exist.
13. **Everything is uncommitted.** One test count and one `swift test` run away from a bad day.

## Opportunities

1. **Preemption is the moat.** Nothing shipped on macOS acts on a partial transcript for
   app-level effects. Extend the allowlist deliberately ("switch to Slack", "open
   github.com/…") and publish the measured time-to-first-action. That number is the one the
   demos quote, and now it can be measured rather than asserted.
2. **Deterministic lanes are cheap to widen.** Volume, dark mode and lock took a day. Alarms,
   timers, brightness, Focus, music transport, screenshots and lock are another three days, all
   offline, all model-free, all under 150 ms. This is where "Siri parity, but instant" is won.
3. **Alarms that fire with pp quit** is a differentiating feature, not table stakes: Siri does
   it, and a slim local assistant that does it is credible in a way that a command runner is
   not.
4. **The learned-skills cache** (`learned.json`) turns every novel command into a sub-20 ms
   repeat. Combined with `MacroMiner` it is a real per-install advantage that costs no model.
5. **Publish the numbers nobody else publishes.** p50/p95 per lane on an M3 Air, cold and
   sustained, with `powermetrics` thermals. The market is full of 200 ms claims from data
   centres; a table measured on a fanless laptop is a marketing asset.
6. **The fixture-replay method generalises to every new lane.** A recorded partial stream or a
   recorded tree plus an expected action sequence replays in milliseconds, so new lanes ship
   with regression coverage by default. That is the thing that keeps velocity high for months.
7. **Bring-your-own-model as a positioning statement.** Model links or your key, no vendor
   lock-in, no cloud in the default path. Already implemented; worth a page.
8. **Training-trace schema already exists** (`TrainingTrace`, `AdapterPromotion`). Start
   collecting consented traces now so Phase 7B has data when it starts, without building the
   trainer yet.

## Threats

1. **Truthfulness risk.** Shipping a confirmation that describes work that did not happen is a
   refund-grade bug and, at scale, a legal one. It also destroys the word of mouth that a fast
   assistant depends on.
2. **Apple absorbing the feature set.** Siri with Apple Intelligence is the incumbent. The
   defensible ground is latency, determinism, offline operation, and inspectability, in that
   order. Anything that drifts toward "also a chatbot" gives that ground away.
3. **TCC and entitlement fragility.** Apple Events prompts on first use, Calendar and
   Notifications prompts later, and each one looks like a broken app if it is not walked through
   onboarding. Scripted app control via AppleScript is a shrinking surface on newer macOS.
4. **CDP requires a browser launch flag**, which most users will not set. If the extension path
   is not built, the browser lane looks like a demo-only feature.
5. **Thermals on a fanless M3 Air.** The decision model is per cycle, not continuous, so this is
   manageable, but sustained sessions have not been measured.
6. **Wake-word false triggers** with a loose "pp" phrase, in a room with a television. Low
   impact, high annoyance, and the kill switch only helps if it is discoverable.
7. **Prompt injection through page text** reaching the script proposer. Gate 3 reduces the blast
   radius; the correct rule is that a proposer never sees screen text at all, only the goal and
   the front app.
8. **Single-maintainer bus factor plus uncommitted work.** The last commit is the v1 baseline.
9. **Dependency and licence exposure.** MLX Swift, Laya (Apache-2.0), and if Parakeet EOU is
   adopted, a non-OSI NVIDIA licence that has to be read before it ships.
10. **Quoting one latency number.** Three different waits are already conflated in the source
    material. Pick one, label it, and keep the other two in the docs.

## Where the leverage is, in order

1. Make alarms real, or remove the confirmation. Nothing else matters while the app can lie.
2. Slice the remainder out of the raw transcript, so typed text is exactly what was said.
3. Close the second window and fix the dead cooldown rule: two hours, and the demo stops looking
   like a prototype.
4. Give `DOMIndexer` a transport, or drop row 4 from the contract for v1.
5. Replace the fabricated timing lines with measured marks, and put the real table in
   `docs/BENCHMARKS.md`.

Items 1 through 3 are a day and a half of work between them and remove every claim in this
document that a hostile reviewer could use.
