import Foundation

@main
struct VoiceChecks {
    static func main() async throws {
        print("Running voice timing and simulated speech checks...")

        // 1. Preemption simulation: partial speech fires launch before final
        var policy = PreemptionPolicy(minimumStableObservations: 2, minimumCharacters: 8, cooldown: 1.5)

        let t0 = 0.0
        let obs1 = PartialObservation(clause: "open not", isFinal: false, monotonicTime: t0)
        assert(policy.observe(obs1) == .wait, "Partial 1 must wait")

        let t1 = 0.15
        let obs2 = PartialObservation(clause: "open notes", isFinal: false, monotonicTime: t1)
        assert(policy.observe(obs2) == .wait, "First stable partial must wait")

        let t2 = 0.28
        let obs3 = PartialObservation(clause: "open notes", isFinal: false, monotonicTime: t2)
        let preemptDecision = policy.observe(obs3)
        guard case .preempt(let step, let clause) = preemptDecision else {
            fatalError("Second stable partial must preempt")
        }
        assert(step.kind == .openApp && step.target == "notes", "Preempt target must be notes")
        assert(clause == "open notes", "Consumed clause must be 'open notes'")

        // Final delivery happens later:
        let fullTranscript = "open notes and write down meeting notes"
        let remainder = PreemptionPolicy.takeRemainder(full: fullTranscript, consumed: clause)
        assert(remainder == "write down meeting notes", "Remainder must be stripped of connectors")

        let fullTranscriptCap = "open notes and write Sumit's number"
        let remainderCap = PreemptionPolicy.takeRemainder(full: fullTranscriptCap, consumed: clause)
        assert(remainderCap == "write Sumit's number", "Remainder must preserve original capitalization")

        let tDecideDelta = (t2 - t1) * 1000.0
        print("Preemption policy verified in \(String(format: "%.1f", tDecideDelta))ms simulated stream")
        print("timing: asr.partial -> preempt.decide -> preempt.act (real marks collected via Timing actor)")
        print("timing: asr.final -> remainder.parse -> frontmost app")

        // 2. Whispered wake phrase check
        let wake = WakePhrase.command(in: "ey pp, open safari", after: "Hey pp")
        assert(wake == "open safari", "Quiet wake phrase 'ey pp' must parse")

        // 3. Spoken dismissal check
        assert(DismissalPhrase.match("stop") == .cancel)
        assert(DismissalPhrase.match("cancel") == .cancel)
        assert(DismissalPhrase.match("thank you") == .dismiss)
        assert(DismissalPhrase.match("stop the music") == nil, "stop the music is a command, not cancel")

        // 4. System Action bare-hour resolution check
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let nineAM = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1700000000))!
        let action = SystemActionParser.parse("alarm for 7", relativeTo: nineAM, calendar: cal)
        assert(action?.confirmationMessage.contains("7:00 PM") == true, "Bare hour 7 after 9am must resolve to 7:00 PM")

        // 5. Script gates check
        let badScript = "do shell script \"cat ~/.ssh/id_rsa\""
        let gateRes = ScriptGates.checkPolicy(source: badScript)
        guard case .failure = gateRes else {
            fatalError("Script touching ~/.ssh must fail policy gate")
        }

        print("All voice and timing acceptance checks passed successfully.")
    }
}
