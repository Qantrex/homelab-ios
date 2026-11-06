import Foundation

/// How the app talks, like a weather app's personality setting. Off (the default) is plain; Dry, Snarky and Ultrakill
/// add a take on the most notable fact under Today's headline (`Voice.take`, Takes.swift), a line on empty screens and
/// a notification's subtitle (`Voice.line`). The facts themselves (counts, problem texts, the headline) never change
/// with it, and every take names the fact it comments on.
public enum Personality: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, dry, snarky
    /// The unhinged one: rude, sweary, dark. No slurs, nothing hateful, sexual or about self-harm.
    case ultrakill

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .dry: "Dry"
        case .snarky: "Snarky"
        case .ultrakill: "Ultrakill"
        }
    }

    /// Stored values from any version decode; one this version doesn't know (written by a newer app) is Off, so the
    /// rest of the settings survive a downgrade.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Personality(rawValue: raw.lowercased()) ?? .off
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
        return options[dayNumber(date, calendar) % options.count]
    }

    public static func moment(_ level: TodayMood.Level) -> Moment {
        switch level {
        case .calm: .calm
        case .headsUp: .headsUp
        case .alarm: .alarm
        case .unknown: .unknown
        }
    }

    /// Days since the era began: the same all day, one more tomorrow.
    static func dayNumber(_ date: Date, _ calendar: Calendar) -> Int {
        max(calendar.ordinality(of: .day, in: .era, for: date) ?? 0, 0)
    }

    /// Every line, for the tests and for anyone adding their own. Keep them short (one line on a small phone), free
    /// of names and of anything that only fits my homelab. These have no facts to work with (a notification's
    /// subtitle, an empty screen); the takes on real numbers are in Takes.swift.
    public static func lines(_ moment: Moment, _ personality: Personality) -> [String] {
        switch (personality, moment) {
        case (.off, _):
            []

        case (.dry, .calm):
            ["Nothing needs you.", "The machines are behaving. For now.", "No news, which is the good kind.",
             "Uneventful. As intended.", "All present and quietly whirring."]
        case (.dry, .headsUp):
            ["Worth a look today.", "Not urgent. Not nothing.", "Something would like a word.",
             "A small matter, politely raised."]
        case (.dry, .alarm):
            ["Something needs fixing.", "Best look at this soon.", "Not how it should be.",
             "Rather less fine than usual."]
        case (.dry, .unknown):
            ["Can't see the lab from here.", "No answer from the lab.", "The lab isn't taking calls."]
        case (.dry, .waiting):
            ["Your call.", "Needs a yes or a no.", "Awaiting a decision. Yours."]
        case (.dry, .nothingToApprove):
            ["Nothing waits for you.", "No decisions pending. Restful."]
        case (.dry, .emptyChat):
            ["Ask it something.", "The agent is listening, politely."]

        case (.snarky, .calm):
            ["Suspiciously quiet.", "Nothing's on fire. Yet.", "Go outside. The lab will cope.",
             "Even the cheap hardware behaves.", "Stop refreshing. It's fine."]
        case (.snarky, .headsUp):
            ["Something is sulking.", "Not broken. Just needy.", "A warning. Ignore it at your peril.",
             "One of your boxes wants attention."]
        case (.snarky, .alarm):
            ["Of course it broke now.", "It worked yesterday. Allegedly.", "Coffee first. Then this.",
             "Cheaper than the cloud, they said."]
        case (.snarky, .unknown):
            ["The lab is giving you the silent treatment.", "Tailscale off again?", "Did someone trip over a cable?"]
        case (.snarky, .waiting):
            ["It won't approve itself.", "The agent has ideas again.", "A robot awaits your blessing."]
        case (.snarky, .nothingToApprove):
            ["Nothing to approve. The agent is behaving.", "No requests. The robot is napping."]
        case (.snarky, .emptyChat):
            ["Say something. It's lonely in here.", "It knows your lab better than you do."]

        case (.ultrakill, .calm):
            ["Nothing's broken. Don't you dare touch it.", "All quiet. Pure dumb luck.",
             "Hell froze over: everything works.", "It works. Leave it the hell alone.", "No fires. Go touch some grass."]
        case (.ultrakill, .headsUp):
            ["Something's whining. Deal with it.", "Not dead yet. Give it time.",
             "A warning. Ignore it, see what happens.", "Your lab is sulking. Damn divas."]
        case (.ultrakill, .alarm):
            ["Shit's broken. Go fix it.", "What the hell did you do?", "Something died. Go find the body.",
             "Bloody hell. Phone down, terminal up."]
        case (.ultrakill, .unknown):
            ["The lab's ignoring you. Smart lab.", "No signal. Did you unplug the damn thing?",
             "Silence. Either dead or plotting."]
        case (.ultrakill, .waiting):
            ["Approve it or deny it, damn it.", "The bot did the work. Press the button.",
             "Decide. It's one tap, not surgery."]
        case (.ultrakill, .nothingToApprove):
            ["Nothing to approve. Go do something useful.", "No requests. The bot gave up on you."]
        case (.ultrakill, .emptyChat):
            ["Say something. Make it worth my while.", "Type something, damn it."]
        }
    }
}
