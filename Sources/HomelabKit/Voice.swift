import Foundation

/// How the app talks, like a weather app's personality setting. Off (the default) is plain; Dry, Snarky and Ultrakill
/// add a take on the most notable fact under Today's headline (`Voice.take`, Takes.swift) and a line in every other
/// place a `Voice.Spot` names: Lab's header, an aside under each problem, empty screens and lists, the alert after an
/// action, a notification's subtitle (`Voice.line(for:…)`, VoiceLines.swift). The facts themselves (counts, problem
/// texts, the headline) never change with it and always show plainly next to the line, so the joke can be ignored.
public enum Personality: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, dry, snarky
    /// The far end, a different tier from Snarky: harsh, profane, over the top, merciless about the owner and the lab,
    /// with satire of politics and the news cycle in general terms (EU regulation, the AI hype, rent, inflation,
    /// surveillance, the Magistrat). It mocks the owner, ideas, institutions and systems. Never slurs, jokes about
    /// protected groups, anything sexual, self-harm, real people or threats (TakeTests). Choosing it asks once first
    /// (`UltrakillWarning`).
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

/// The one-time warning when Ultrakill is chosen, in its own voice. Shown until confirmed once
/// (`AppSettings.needsWarning(for:)`); "Back" keeps the previous level.
public enum UltrakillWarning {
    public static let title = "Ultrakill"
    public static let message = "It will insult you, your servers and your life choices. No refunds."
    public static let enable = "Enable"
    public static let back = "Back"
}

/// The one-time warning when Hyperdetail is chosen (`AppSettings.needsWarning(for: Density)`). "Back" keeps the
/// previous level. Plain on purpose: the personality is not asked to speak here.
public enum HyperdetailWarning {
    public static let title = "Hyperdetail"
    public static let message = "Everything. Every number, every timestamp, everywhere, unfolded. Your screen will scroll forever. Why would you want that?"
    public static let enable = "Do it"
    public static let back = "Back"
}

public enum Voice {
    /// Where a line can appear.
    public enum Moment: CaseIterable, Sendable {
        case calm, headsUp, alarm, unknown   // Today's headline, by mood
        case waiting                         // a notification for an action to approve
        case nothingToApprove, emptyChat     // empty screens

        /// The same place as a `Spot` (which has every place the voice speaks in).
        public var spot: Spot {
            switch self {
            case .calm: .today(.calm)
            case .headsUp: .today(.headsUp)
            case .alarm: .today(.alarm)
            case .unknown: .today(.unknown)
            case .waiting: .notice(.waiting)
            case .nothingToApprove: .empty(.approvals)
            case .emptyChat: .empty(.chat)
            }
        }
    }

    /// One line for the moment, nil when the personality is off. The pick changes with the day, not with every
    /// refresh, so the line doesn't jump around while the screen is open.
    public static func line(_ moment: Moment, _ personality: Personality, on date: Date = Date(),
                            calendar: Calendar = .current) -> String? {
        line(for: moment.spot, personality: personality, now: date, calendar: calendar)
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

    /// Every line for a moment (the same as `lines(for: moment.spot, …)`), for the tests and for anyone adding their
    /// own. The lines themselves are in VoiceLines.swift; the takes on real numbers are in Takes.swift.
    public static func lines(_ moment: Moment, _ personality: Personality) -> [String] {
        VoiceLines.all(moment.spot.place, personality)
    }
}
