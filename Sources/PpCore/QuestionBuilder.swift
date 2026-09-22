import Foundation

/// A question in the exact shape the Laya heads expect: ordered options, and the id
/// each option index maps back to.
public struct LayaQuestion: Equatable, Sendable {
    public let id: String
    public let type: String
    public let instructions: String
    public let options: [String]
    /// Parallel to `options`. Index i of a prediction means `optionIDs[i]`.
    public let optionIDs: [String]

    public init(id: String, type: String, instructions: String, options: [String], optionIDs: [String]) {
        self.id = id; self.type = type; self.instructions = instructions
        self.options = options; self.optionIDs = optionIDs
    }

    public func id(forIndex index: Int) -> String? {
        (0..<optionIDs.count).contains(index) ? optionIDs[index] : nil
    }
}

/// Builds the specialist question set: router, target, action kind, safety, completion.
///
/// The head block is 192 tokens and each option is capped at 48 tokens of text, so the
/// option lists here stay short on purpose. Anything that needs the full screen goes
/// through `Shortlister` first.
public enum QuestionBuilder {
    public enum Route: String, Sendable, CaseIterable {
        case app, browser, system, plugin, conversation
    }

    /// Where should this command be handled?
    public static func router(goal: String, availablePlugins: [String] = []) -> LayaQuestion {
        var routes: [Route] = [.app, .browser, .system]
        if !availablePlugins.isEmpty { routes.append(.plugin) }
        routes.append(.conversation)

        let descriptions: [Route: String] = [
            .app: "the goal is about an application on this Mac, its windows, menus or controls",
            .browser: "the goal is about a web page, site, search or link",
            .system: "the goal is about macOS itself: volume, brightness, files, windows, system settings",
            .plugin: "the goal is about a service one of the installed plugins provides",
            .conversation: "the goal is not a desktop action: it is a question or a remark to answer"
        ]

        return LayaQuestion(
            id: "router",
            type: "choice",
            instructions: "Which kind of work does the command '\(goal)' belong to?",
            options: routes.map { "\($0.rawValue): \(descriptions[$0] ?? "")" },
            optionIDs: routes.map(\.rawValue)
        )
    }

    /// Which listed control is the step talking about?
    public static func target(goal: String, step: PlanStep, candidates: [Candidate]) -> LayaQuestion {
        let options = candidates.map { "\($0.label): \($0.detail)" } + ["none: no listed item matches"]
        return LayaQuestion(
            id: "target",
            type: "choice",
            instructions: "Which listed control is the one step '\(step.summary)' means, for the goal '\(goal)'? The last option means none of them.",
            options: options,
            optionIDs: candidates.map(\.id) + ["none"]
        )
    }

    /// What kind of action is being asked for?
    public static func actionKind(goal: String) -> LayaQuestion {
        let kinds = ["click", "type_text", "press_key", "menu", "scroll", "open_app", "open_url", "open_folder", "quit_app", "skip"]
        return LayaQuestion(
            id: "kind",
            type: "choice",
            instructions: "Which single kind of action does the goal '\(goal)' ask for?",
            options: kinds.map { "\($0): \(actionKindDescription($0))" },
            optionIDs: kinds
        )
    }

    private static func actionKindDescription(_ kind: String) -> String {
        switch kind {
        case "click": return "press a control or link on screen"
        case "type_text": return "enter text into an input"
        case "press_key": return "press a named key such as return or escape"
        case "menu": return "choose a menu item"
        case "scroll": return "move the content"
        case "open_app": return "bring up an application"
        case "open_url": return "bring up a web address"
        case "open_folder": return "bring up a folder"
        case "quit_app": return "close an application"
        case "skip": return "skip media forward or back"
        default: return ""
        }
    }

    /// Should this step run without asking? A veto, not a vote.
    public static func safety(stepSummary: String, goal: String) -> LayaQuestion {
        LayaQuestion(
            id: "safe",
            type: "noul",
            instructions: "Step '\(stepSummary)' is about to be performed for the goal '\(goal)'. Does it send data outward, delete data, spend money, or change system state?",
            options: ["false: it only moves around inside this Mac and changes nothing outside it",
                      "true: it sends, deletes, spends or changes system state"],
            optionIDs: ["false", "true"]
        )
    }

    /// Is the whole command finished?
    public static func completion(goal: String, lastAction: String) -> LayaQuestion {
        LayaQuestion(
            id: "finished",
            type: "noul",
            instructions: "After '\(lastAction)', is the goal '\(goal)' completely finished with nothing left to do?",
            options: ["false: the goal still asks for more",
                      "true: everything the goal asked for has happened"],
            optionIDs: ["false", "true"]
        )
    }

    /// Has the step's effect already happened?
    public static func alreadyDone(step: PlanStep, goal: String) -> LayaQuestion {
        LayaQuestion(
            id: "already_done",
            type: "noul",
            instructions: "Does the screen already show that step '\(step.summary)' for the goal '\(goal)' has been completed, so repeating it would be redundant?",
            options: ["false: the step still needs to be performed",
                      "true: the step's effect is already visible"],
            optionIDs: ["false", "true"]
        )
    }

    /// How good is this candidate, 0 upwards? Asked on the score head.
    public static func quality(goal: String, levels: [String]) -> LayaQuestion {
        LayaQuestion(
            id: "quality",
            type: "score",
            instructions: "How well does the current screen match what the goal '\(goal)' needs?",
            options: levels.enumerated().map { "level \($0.offset): \($0.element)" },
            optionIDs: levels.indices.map(String.init)
        )
    }

    /// Reads a yes/no answer out of a noul prediction. Options are always false, true.
    public static func yesProbability(_ probabilities: [Float]) -> Double {
        probabilities.count > 1 ? Double(probabilities[1]) : 0
    }
}
