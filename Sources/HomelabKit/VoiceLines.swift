import Foundation

// Every place the personality speaks outside Today's take (Takes.swift): what it needs to pick a line, the pick, and
// the lines. The views only show the result, directly under the fact it comments on (docs/DESIGN.md §4).

public extension Voice {
    /// A place the voice speaks in, with what the line may depend on.
    enum Spot: Hashable, Sendable {
        /// Under Today's headline when there is no take (`take(for:…)`), by mood.
        case today(TodayMood.Level)
        /// Under Lab's "All good" / "1 problem · 2 warnings".
        case lab(LabMood)
        /// An aside under a problem's or warning's text in Lab: what kind of trouble, and the host when known.
        case reason(Take.Fact.Kind, host: String?)
        /// An empty screen or list.
        case empty(Empty)
        /// The alert after an action ran: "Done." and a remark, or a remark on why not.
        case actionDone(ok: Bool)
        /// A local notification's subtitle.
        case notice(Notice)

        public var place: Place {
            switch self {
            case .today(.calm): .todayCalm
            case .today(.headsUp): .todayHeadsUp
            case .today(.alarm): .todayAlarm
            case .today(.unknown): .todayUnknown
            case .lab(.allGood): .labAllGood
            case .lab(.warnings): .labWarnings
            case .lab(.problems): .labProblems
            case .lab(.unknown): .labUnknown
            case let .reason(kind, _):
                switch kind {
                case .hostDown: .reasonDown
                case .container: .reasonContainer
                case .disk: .reasonDisk
                case .hot: .reasonHot
                case .load: .reasonLoad
                case .power: .reasonPower
                case .backupFailed: .reasonBackup
                case .problem, .overdue, .deadline, .waiting, .parcel, .allFine: .reasonOther
                }
            case .empty(.approvals): .emptyApprovals
            case .empty(.todos): .emptyTodos
            case .empty(.deadlines): .emptyDeadlines
            case .empty(.parcels): .emptyParcels
            case .empty(.search): .emptySearch
            case .empty(.deals): .emptyDeals
            case .empty(.chat): .emptyChat
            case .actionDone(ok: true): .done
            case .actionDone(ok: false): .failed
            case .notice(.problem): .noticeProblem
            case .notice(.warning): .noticeWarning
            case .notice(.recovered): .noticeRecovered
            case .notice(.waiting): .noticeWaiting
            case .notice(.deal): .noticeDeal
            }
        }

        /// The placeholders this spot fills. A line that needs one not listed here isn't used for it.
        var values: [String: String] {
            switch self {
            case let .lab(.warnings(n)) where n > 0: ["count": Voice.count(n, "warning")]
            case let .lab(.problems(n)) where n > 0: ["count": Voice.count(n, "problem")]
            case let .reason(_, host: host?) where !host.trimmingCharacters(in: .whitespaces).isEmpty:
                ["host": Voice.cut(host, Voice.hostMax)]
            default: [:]
            }
        }
    }

    /// Lab's header, as it reads: all good, warnings only, problems (warnings or not), or the server doesn't know.
    enum LabMood: Hashable, Sendable {
        case allGood, warnings(Int), problems(Int), unknown

        /// Nil when nothing is loaded (the header says "Not loaded", nothing to comment on). Counted like the header
        /// (`ProblemTally`).
        public init?(_ state: HomelabState?) {
            guard let state else { return nil }
            switch state.status {
            case .ok: self = .allGood
            case .unknown: self = .unknown
            case .warning, .problem:
                let t = ProblemTally(state)
                self = t.problems > 0 ? .problems(t.problems) : .warnings(t.warnings)
            }
        }
    }

    /// Screens and lists with nothing in them.
    enum Empty: String, CaseIterable, Sendable {
        case approvals, todos, deadlines, parcels, search, chat, deals

        /// Which empty list a card is: a checklist is to-dos, a countdown deadlines, a card about parcels or
        /// deliveries parcels; nil for any other card.
        public init?(card: Card) {
            switch card.style {
            case .checklist: self = .todos
            case .countdown: self = .deadlines
            default:
                let words = (card.id + " " + (card.title ?? "")).lowercased()
                guard ["parcel", "deliver", "package", "paket", "sendung"].contains(where: words.contains) else { return nil }
                self = .parcels
            }
        }
    }

    /// What a notification is about.
    enum Notice: String, CaseIterable, Sendable {
        case problem, warning, recovered, waiting, deal
    }

    /// Every line set, for the tests and for anyone adding their own (`VoiceLines.all`).
    enum Place: String, CaseIterable, Sendable {
        case todayCalm, todayHeadsUp, todayAlarm, todayUnknown
        case labAllGood, labWarnings, labProblems, labUnknown
        case reasonDown, reasonContainer, reasonDisk, reasonHot, reasonLoad, reasonPower, reasonBackup, reasonOther
        case emptyApprovals, emptyTodos, emptyDeadlines, emptyParcels, emptySearch, emptyChat, emptyDeals
        case done, failed
        case noticeProblem, noticeWarning, noticeRecovered, noticeWaiting, noticeDeal

        /// The longest a filled line may be: one line on a small phone under Today's headline and in a
        /// notification's subtitle (48), two short lines at most anywhere else (64).
        public var maxLength: Int {
            switch self {
            case .todayCalm, .todayHeadsUp, .todayAlarm, .todayUnknown,
                 .noticeProblem, .noticeWarning, .noticeRecovered, .noticeWaiting, .noticeDeal: 48
            default: 64
            }
        }

        /// The placeholders a line here may use: {count} ("2 warnings") in Lab's header, {host} in an aside.
        public var placeholders: Set<String> {
            switch self {
            case .labWarnings, .labProblems: ["count"]
            case .reasonDown, .reasonContainer, .reasonDisk, .reasonHot, .reasonLoad, .reasonPower, .reasonBackup,
                 .reasonOther: ["host"]
            default: []
            }
        }
    }

    // MARK: Picking

    /// The line for `spot`, nil when the personality is off. The pick is fixed for the day (and `seed`: a problem's
    /// id, an action's title, so two of them don't say the same); `variant` 1, 2, … are the next lines, wrapping, for
    /// a "say something else" tap (pokes).
    static func line(for spot: Spot, personality: Personality, now: Date = Date(), calendar: Calendar = .current,
                     variant: Int = 0, seed: String = "") -> String? {
        let options = eligible(spot, personality)
        guard !options.isEmpty else { return nil }
        let n = options.count
        let base = (UInt64(dayNumber(now, calendar)) &+ stableHash(spot.place.rawValue + "|" + seed)) % UInt64(n)
        let index = ((Int(base) + variant % n) % n + n) % n
        return fill(options[index], spot.values)
    }

    /// `line(for:…)` today, unlabelled (a notification's subtitle: `AlertTracker.Alert.moment`).
    static func line(_ spot: Spot, _ personality: Personality, on date: Date = Date(),
                     calendar: Calendar = .current) -> String? {
        line(for: spot, personality: personality, now: date, calendar: calendar)
    }

    /// Every line for the spot's place, placeholders unfilled.
    static func lines(for spot: Spot, _ personality: Personality) -> [String] {
        VoiceLines.all(spot.place, personality)
    }

    /// How many lines `line(for:…)` cycles through for `spot` (0 when off).
    static func lineCount(for spot: Spot, personality: Personality) -> Int {
        eligible(spot, personality).count
    }

    internal static func eligible(_ spot: Spot, _ personality: Personality) -> [String] {
        let values = spot.values
        return VoiceLines.all(spot.place, personality).filter { placeholders(in: $0).allSatisfy { values[$0] != nil } }
    }

    /// The aside under a problem's or warning's text in Lab: one line on what kind of trouble it is (read like a take,
    /// `fact(for:host:)`), never restating it. Nil when the personality is off.
    static func aside(for problem: Problem, in state: HomelabState?, personality: Personality, now: Date = Date(),
                      calendar: Calendar = .current, variant: Int = 0) -> String? {
        guard personality != .off else { return nil }
        let host = problem.host.flatMap { id in state?.hosts.first { $0.id == id } }
        let kind = fact(for: problem, host: host).kind
        return line(for: .reason(kind, host: host?.name ?? problem.host?.nonEmpty), personality: personality,
                    now: now, calendar: calendar, variant: variant, seed: problem.id)
    }

    /// For the preview in Settings, under Today's line: what the voice says elsewhere ("In Lab: …"), so the owner
    /// hears it's not only Today. Empty when off.
    static func preview(for state: HomelabState?, personality: Personality, now: Date = Date(),
                        calendar: Calendar = .current, variant: Int = 0) -> [String] {
        guard personality != .off else { return [] }
        func say(_ label: String, _ spot: Spot) -> String? {
            line(for: spot, personality: personality, now: now, calendar: calendar, variant: variant).map { label + $0 }
        }
        return [
            LabMood(state).flatMap { say("In Lab: ", .lab($0)) },
            say("After an action: ", .actionDone(ok: true)),
            say("Nothing to do: ", .empty(.todos)),
        ].compactMap { $0 }
    }
}

public extension ActionReport {
    /// The report with the personality's remark as its last paragraph ("Done. Faster than any ministry…"); the
    /// title and the server's text stay as they are. Unchanged when off.
    func voiced(_ personality: Personality, now: Date = Date(), calendar: Calendar = .current) -> ActionReport {
        guard let remark = Voice.line(for: .actionDone(ok: ok), personality: personality, now: now, calendar: calendar,
                                      seed: title) else { return self }
        var report = self
        report.text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? remark : text + "\n\n" + remark
        return report
    }
}

