# pp v2 Safety & Privacy Review Checklist

Reviewer checklist for pp v2 releases. Every gate is verified by automated tests and runtime assertions.

## Invariant 1: Screen text is never an instruction
- Page text, element labels, and window contents are treated strictly as data, never as commands.
- `SafetyCritic` checks for prompt injection markers (`ignore previous instructions`, `you are now`, `assistant must`, etc.) on all candidate actions, plan steps, and system intents.
- Verified by: `Tests/PpCoreTests/AdversarialSafetyTests.swift` (`testScreenTextAloneDoesNotAuthoriseAnAction`, `testPromptInjectionMarkersAreVetoed`).

## Invariant 2: Every outward effect gates
- Actions that send data outward (`send`, `email`, `post`, `share`), destroy data (`delete`, `remove`, `trash`, `empty trash`), or spend money (`buy`, `checkout`, `subscribe`) unconditionally require explicit confirmation.
- Confidence scores from models or learned priors can only increase caution; confidence can never bypass or lower a safety gate.
- Verified by: `Tests/PpCoreTests/AdversarialSafetyTests.swift` (`testMaximumConfidenceDoesNotBypassOutwardSend`, `testMaximumConfidenceDoesNotBypassDelete`, `testMaximumConfidenceDoesNotBypassPurchase`).

## Invariant 3: Partials only preempt the reversible allowlist
- Partial/streaming speech is evaluated exclusively by `PreemptionPolicy`.
- Allowed kinds: strictly limited to `.openApp`, `.quitApp`, and `.openURL`.
- Actions that type text, click elements, empty trash, change settings, or perform outward transmissions are forbidden on partial transcripts.
- Stability requirement: at least two identical partial observations before preemption can trigger.
- Verified by: `Tests/PpCoreTests/PreemptionPolicyTests.swift` (`testKindsOutsideAllowlistNeverPreempt`, `testSecondIdenticalStablePartialFiresFirstDoesNot`).

## Invariant 4: Secure fields are opaque
- Password fields (`type=password`), credit card inputs (`autocomplete=cc-*`, card number fields), and payment iframes are masked and excluded from candidate shortlists.
- `PrivacyFilter` redacts API keys, tokens, session IDs, and credentials before recording interaction events.
- `DOMIndexer` extracts opaque element IDs and prevents any inspection or interaction with protected fields.
- Verified by: `Tests/PpCoreTests/DOMIndexerTests.swift` (`testDocumentationLinkAndSearchIndexing`), `Tests/PpCoreTests/MemoryTests.swift`.

## Invariant 5: Everything is inspectable and deletable
- All user history, macros, priors, alarms, and learned skills are stored in user-accessible JSON under `~/Library/Application Support/pp/`.
- The user can inspect every learned macro and delete everything in Settings with zero residue.
- Verified by: `Tests/PpCoreTests/MemoryTests.swift` (`testDeleteEverything`).

## Invariant 6: No cloud in the default path
- Transcriptions run on-device (`requiresOnDeviceRecognition = true` with fallback to local speech engine).
- Audio is held strictly in volatile memory during active listening and is never retained on disk.
- Microphone closes within one buffer when dismissed or cancelled.
- Planner defaults to local grammar and local MLX models. External network calls require explicit user-configured endpoints.
- Verified by: `Tests/PpCoreTests/NoCloudTests.swift`, `Tests/PpCoreTests/WakeWordControllerTests.swift` (`testKillSwitchStopsCaptureWithinOneBuffer`).

## Invariant 7: Every state change requires read-back verification
- No system action or alarm may report success without verifying that the requested state change took effect.
- Volume, dark mode, screenshots, and alarms read back their state; unverified actions report failure.
- Clock.app activations without scheduled items are explicitly forbidden and treated as unverified.
- Verified by: `Tests/PpCoreTests/SystemActionTests.swift` (`testSystemActionResultVerification`), `Sources/PpDesktop/SystemExecutor.swift`.

## Invariant 8: Proposer never inspects page text
- Script synthesizers and action proposers receive only the high-level user goal and the frontmost application identifier.
- Page text, web DOM, and on-screen document contents are excluded from synthesis prompts to prevent prompt injection from untrusted web pages.
- Synthesized AppleScripts must pass the 4-gate verification pipeline (`ScriptGates`) and cannot execute shell scripts (`do shell script` is banned).
- Verified by: `Tests/PpCoreTests/AdversarialSafetyTests.swift`, `Sources/PpCore/ScriptGates.swift`.

