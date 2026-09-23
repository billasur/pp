# pp v3 Manual Acceptance Battery

Run through this 12-item checklist on physical hardware with live audio, real applications, and notification permissions configured.

| # | Acceptance Test | Description & Steps | Expected Result | Pass/Fail |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **Wake by whisper** | Speak "pp" or "hey pp" in a low whisper near the mic. | Audio ring buffer catches energy, wakes session, island illuminates. | [ ] |
| 2 | **Wake mid-room** | Speak "pp open finder" from ~3 meters across the room. | Session arms without dropping leading syllables; Finder opens. | [ ] |
| 3 | **Three commands in one session** | Speak: "pp open notes", then "open calendar", then "open calculator" without repeating wake word. | All three clauses execute seamlessly within the continuous `WakeSession`. | [ ] |
| 4 | **"bye" closes mic** | Speak "bye", "goodbye", or "that's all". | Microphone closes immediately, island returns to idle, hands-free disengages. | [ ] |
| 5 | **Zen by name** | Speak "open zen". | App name matcher resolves Zen Browser (or Zen) and launches it directly. | [ ] |
| 6 | **Zen with an alias** | Speak "open zen browser". | Alias table collapses "zen browser" to "Zen" and opens it without fallback. | [ ] |
| 7 | **YouTube search** | Speak "search youtube for lofi hip hop". | Opens preferred browser directly to `https://www.youtube.com/results?search_query=lofi+hip+hop`. | [ ] |
| 8 | **YouTube.com open** | Speak "search youtube.com" or "open youtube.com". | Opens preferred browser navigation directly to `https://www.youtube.com`. | [ ] |
| 9 | **WhatsApp send with confirmation** | Speak "whatsapp Diya saying the launch is tomorrow". | Island displays "Send WhatsApp to Diya? \"the launch is tomorrow\"". Message is held until user says "send it" or presses ⌘↩. | [ ] |
| 10 | **Alarm rings with pp quit** | Set an alarm for 2 minutes out ("alarm for 2 minutes"). Quit pp. | macOS UNUserNotification rings with banner and sound at scheduled time. | [ ] |
| 11 | **Alarm rings with pp open** | Set an alarm for 1 minute out while pp is running in foreground/background. | In-app ringer plays looping alert sound, island switches to `.alarm` state, voice "stop" or Stop button silences it. | [ ] |
| 12 | **Two capsules around notch** | Trigger pp voice input on notched display (MacBook Air/Pro). | Exactly two capsules appear flanking the notch (left: indicator/cancel, right: headline/transcript). No overlay at bottom of screen. | [ ] |
