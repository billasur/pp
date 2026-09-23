# Release QA Checklist for pp v2.1

Checklist for manual QA and release staging on macOS 14.2+ (Apple Silicon).

## 1. Clean Account Installation
- [ ] Install `pp.dmg` on a clean macOS user account with no prior `pp` data.
- [ ] Launch `pp.app` and verify Onboarding displays explanations for all requested permissions (Accessibility, Microphone, Speech Recognition, Automation, Notifications).
- [ ] Verify no background crashes or permissions panics occur prior to user grant.

## 2. Permission Revocation Handling
- [ ] In `System Settings → Privacy & Security → Accessibility`, revoke `pp`.
- [ ] Attempt a command; verify `pp` shows a clear, non-crash prompt directing user to Accessibility settings.
- [ ] Deny Notifications in System Settings; set an alarm; verify `pp` reports failure rather than fabricating a confirmation.

## 3. Alarms & Timers Persistence
- [ ] Speak: *"Set an alarm for two minutes from now"*.
- [ ] Verify alarm is listed in `pp`.
- [ ] Quit `pp` (`⌘Q`).
- [ ] Wait for two minutes; verify the notification fires with critical alert sound even while `pp` is closed.
- [ ] Reopen `pp`; speak *"Cancel alarm"*; verify cancellation succeeds and pending notifications are cleared.

## 4. Truthfulness & Read-back Verification
- [ ] Speak: *"Volume to fifty percent"*. Verify volume changes to 50% and read-back confirms `Volume is 50%`.
- [ ] Speak: *"Turn on dark mode"*. Verify system switches appearance and read-back confirms `Dark mode active`.
- [ ] Speak: *"Take a screenshot"*. Verify screenshot is written to Desktop and path is displayed.

## 5. Offline Operation
- [ ] Disconnect Wi-Fi and Ethernet.
- [ ] Speak: *"Open Notes and write meeting notes"*.
- [ ] Verify preemption launches Notes and types the remainder without network access.
- [ ] Speak: *"Volume up"*; verify execution succeeds 100% offline.

## 6. Signature & Entitlement Verification
- [ ] Run `codesign -d --entitlements :- /Applications/pp.app`
- [ ] Verify `com.apple.security.automation.apple-events` is present.
- [ ] Verify `spctl --assess --type execute /Applications/pp.app` returns accepted.
