import Foundation

/// How the app talks, like a weather app's personality setting. Off (the default) is plain; Dry, Snarky and Ultrakill
/// add a take on the most notable fact under Today's headline (`Voice.take`, Takes.swift), a line on empty screens and
/// a notification's subtitle (`Voice.line`). The facts themselves (counts, problem texts, the headline) never change
/// with it, and every take names the fact it comments on.
public enum Personality: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, dry, snarky
    /// CARROT's far end: gallows humour, bleak cynicism, politically incorrect takes on institutions and ideas, the odd
    /// swear word. Never slurs, jokes demeaning protected groups, anything sexual, self-harm, real people or threats.
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

    /// What the voice says under Today's headline, for the preview in Settings: the take on the most notable fact of
    /// `state`, else the mood's general line; nil when the personality is off. `variant` moves on like a tap on
    /// Today's line does.
    public static func sample(for state: HomelabState?, level: TodayMood.Level, personality: Personality,
                              variant: Int = 0, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let variant = max(variant, 0)
        let count = takeCount(for: state, personality: personality, now: now, calendar: calendar)
        if count > 0, let t = take(for: state, personality: personality, now: now, calendar: calendar,
                                   variant: variant % count) {
            return t.text
        }
        let all = lines(moment(level), personality)
        guard !all.isEmpty else { return nil }
        return all[(dayNumber(now, calendar) + variant) % all.count]
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
            ["Nothing's broken. Enjoy it. Nothing lasts.", "All quiet. Entropy is just pacing itself.",
             "Everything works. Suspicious, in this economy.", "It works. Leave it alone, you menace.",
             "Calm. Like a morgue."]
        case (.ultrakill, .headsUp):
            ["Something's dying slowly. Like the EU's plans.", "Not dead yet. Give it time.",
             "A warning. Ignore it like the climate reports.", "Your lab is sulking. Draft the eulogy."]
        case (.ultrakill, .alarm):
            ["Shit's broken. Go fix it.", "Something died. Go find the body.",
             "Time of death: just now. Cause: you.", "Another casualty of your homelab."]
        case (.ultrakill, .unknown):
            ["The lab's ignoring you. Smart lab.", "No signal. Either dead or unionising.",
             "Silence. Like the Magistrat on a Friday."]
        case (.ultrakill, .waiting):
            ["Decide. Faster than the Magistrat, ideally.", "The bot did the work. Press the button.",
             "Approve it before entropy does."]
        case (.ultrakill, .nothingToApprove):
            ["Nothing to approve. Go be productive. Or don't.", "No requests. The bot gave up on you."]
        case (.ultrakill, .emptyChat):
            ["Say something. We're all dying anyway.", "Type something. The void is listening."]
        }
    }
}
