import Foundation

/// How the app talks, like a weather app's personality setting. Off (the default) is plain; Dry and Snarky add one
/// line under Today's headline, on empty screens and as a notification's subtitle. Facts (counts, problem texts, the
/// headline itself) never change with it.
public enum Personality: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, dry, snarky

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .dry: "Dry"
        case .snarky: "Snarky"
        }
    }
}

public enum Voice {
    /// Where a line can appear.
    public enum Moment: CaseIterable, Sendable {
        case calm, headsUp, alarm, unknown   // Today's headline, by mood
        case waiting                         // a notification for an action to approve
        case nothingToApprove, emptyChat     // empty screens
    }

    /// One line for the moment, nil when the personality is off. The pick changes with the day, not with every
    /// refresh, so the line doesn't jump around while the screen is open.
    public static func line(_ moment: Moment, _ personality: Personality, on date: Date = Date(),
                            calendar: Calendar = .current) -> String? {
        let options = lines(moment, personality)
        guard !options.isEmpty else { return nil }
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return options[day % options.count]
    }

    public static func moment(_ level: TodayMood.Level) -> Moment {
        switch level {
        case .calm: .calm
        case .headsUp: .headsUp
        case .alarm: .alarm
        case .unknown: .unknown
        }
    }

    /// Every line, for the tests and for anyone adding their own. Keep them short (one line on a small phone), free
    /// of names and of anything that only fits my homelab.
    public static func lines(_ moment: Moment, _ personality: Personality) -> [String] {
        switch (personality, moment) {
        case (.off, _):
            []
        case (.dry, .calm):
            ["Nothing needs you.", "Everything is where you left it.", "The machines are behaving.", "No news. Good news."]
        case (.dry, .headsUp):
            ["Worth a look today.", "Not urgent. Not nothing.", "Something would like a word."]
        case (.dry, .alarm):
            ["Something needs fixing.", "Best look at this soon.", "Not how it should be."]
        case (.dry, .unknown):
            ["Can't see the lab from here.", "No answer from the lab."]
        case (.dry, .waiting):
            ["Your call.", "Needs a yes or a no."]
        case (.dry, .nothingToApprove):
            ["Nothing waits for you."]
        case (.dry, .emptyChat):
            ["Ask it something."]
        case (.snarky, .calm):
            ["Suspiciously quiet.", "Nothing's on fire. Yet.", "Go outside. The lab will cope.", "Even the cheap hardware behaves."]
        case (.snarky, .headsUp):
            ["Something is sulking.", "Not broken. Just needy.", "A warning. Ignore it at your peril."]
        case (.snarky, .alarm):
            ["Of course it broke now.", "Well, that's not great.", "It worked yesterday. Allegedly.", "Coffee first. Then this."]
        case (.snarky, .unknown):
            ["The lab is giving you the silent treatment.", "Tailscale off again?"]
        case (.snarky, .waiting):
            ["It won't approve itself.", "The agent has ideas again."]
        case (.snarky, .nothingToApprove):
            ["Nothing to approve. The agent is behaving."]
        case (.snarky, .emptyChat):
            ["Say something. It's lonely in here."]
        }
    }
}
