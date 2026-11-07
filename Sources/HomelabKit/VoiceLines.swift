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

/// The lines. Rules (VoiceTests): a full sentence, within the place's `maxLength` once filled, distinct per
/// personality, no markdown characters (some go through `LocalizedStringKey`), no "Ah," / "Let's" / dashes. "Done."
/// starts every line after an action that worked. Dry is deadpan with the odd dig at officialdom; Snarky mocks the
/// owner and the hardware, with a little politics; Ultrakill is gallows humour and politically incorrect satire of
/// institutions, ideologies and current politics. All of them mock ideas, institutions and systems, never groups of
/// people: no slurs, nothing about protected groups, nothing sexual, no self-harm, no real named people, no violence.
enum VoiceLines {
    static func all(_ place: Voice.Place, _ p: Personality) -> [String] {
        switch p {
        case .off: []
        case .dry: dry(place)
        case .snarky: snarky(place)
        case .ultrakill: ultrakill(place)
        }
    }

    // MARK: Dry

    static func dry(_ place: Voice.Place) -> [String] {
        switch place {
        case .todayCalm:
            ["Nothing needs you.", "The machines are behaving. For now.", "No news, which is the good kind.",
             "Uneventful. As intended.", "All present and quietly whirring."]
        case .todayHeadsUp:
            ["Worth a look today.", "Not urgent. Not nothing.", "Something would like a word.",
             "A small matter, politely raised."]
        case .todayAlarm:
            ["Something needs fixing.", "Best look at this soon.", "Not how it should be.",
             "Rather less fine than usual."]
        case .todayUnknown:
            ["Can't see the lab from here.", "No answer from the lab.", "The lab isn't taking calls."]

        case .labAllGood:
            ["Nothing to report. Enjoy the silence.", "All in order. Unusually so.",
             "Nothing amiss. Rather like a well-run ministry, in theory."]
        case .labWarnings:
            ["{count}. Nothing urgent, nothing ideal.", "A few things would like a word.",
             "{count}, filed for later. Not too much later."]
        case .labProblems:
            ["{count}. Best not put this off.", "Something has stopped. It won't restart out of politeness."]
        case .labUnknown:
            ["No word from the server. Patience, or a cable.", "Unclear. Much like the official forecasts."]

        case .reasonDown:
            ["Not answering. Possibly on a coffee break.", "Gone quiet. Rarely a good sign."]
        case .reasonContainer:
            ["A restart usually does it.", "Containers do this. Regrettably often."]
        case .reasonDisk:
            ["Space is finite. So, it seems, is patience.", "Something will have to go."]
        case .reasonHot:
            ["Warm. Airflow is a wonderful thing.", "Running warm. The cupboard may be to blame."]
        case .reasonLoad:
            ["Busy. More than its fair share, as usual.", "Working hard. Rather more than it was paid for."]
        case .reasonPower:
            ["Cheap power supplies are rarely a saving.", "Short of power. As is everyone, these days."]
        case .reasonBackup:
            ["Best fixed before it matters.", "A backup that fails is merely a hope."]
        case .reasonOther:
            ["Noted. It won't fix itself.", "One for the list, near the top.", "Not ideal. Not the end, either."]

        case .emptyApprovals:
            ["Nothing waits for you.", "No decisions pending. Restful.", "A clear desk. Rare, and welcome."]
        case .emptyTodos:
            ["Nothing to do. Suspicious, but welcome.", "List empty. Savour it."]
        case .emptyDeadlines:
            ["Nothing due. Enjoy the breathing room.", "No deadlines in sight. For now."]
        case .emptyParcels:
            ["Nothing on its way. Your wallet thanks you.", "No parcels expected."]
        case .emptySearch:
            ["Nothing by that name. Perhaps another spelling.", "No match. The catalogue has its limits."]
        case .emptyChat:
            ["Ask it something.", "The agent is listening, politely.", "Questions welcome. Brief ones preferred."]

        case .emptyDeals:
            ["No bargains today. The market is behaving.", "Nothing underpriced. The sellers are awake."]

        case .done:
            ["Done. As requested.", "Done. Quietly and without fuss.",
             "Done. Fewer forms than the Magistrat would need."]
        case .failed:
            ["That didn't work. The details are above.", "No luck this time. Worth another try."]

        case .noticeProblem:
            ["Something has broken. Best look soon.", "A problem, freshly arrived."]
        case .noticeWarning:
            ["Something would like your attention.", "A gentle warning. For now."]
        case .noticeRecovered:
            ["Back to normal. Quietly.", "Sorted itself out. Rather decent of it."]
        case .noticeWaiting:
            ["Your call.", "Needs a yes or a no.", "Awaiting a decision. Yours."]

        case .noticeDeal:
            ["A bargain has turned up. Act soon.", "Something is well under its value."]
        }
    }

    // MARK: Snarky

    static func snarky(_ place: Voice.Place) -> [String] {
        switch place {
        case .todayCalm:
            ["Suspiciously quiet.", "Nothing's on fire. Yet.", "Go outside. The lab will cope.",
             "Even the cheap hardware behaves.", "Stop refreshing. It's fine."]
        case .todayHeadsUp:
            ["Something is sulking.", "Not broken. Just needy.", "A warning. Ignore it at your peril.",
             "One of your boxes wants attention."]
        case .todayAlarm:
            ["Of course it broke now.", "It worked yesterday. Allegedly.", "Coffee first. Then this.",
             "Cheaper than the cloud, they said."]
        case .todayUnknown:
            ["The lab is giving you the silent treatment.", "Tailscale off again?", "Did someone trip over a cable?"]

        case .labAllGood:
            ["All good. Don't touch anything.", "Nothing broken. Must be a public holiday.",
             "All good. Screenshot it for posterity."]
        case .labWarnings:
            ["{count}. Your lab is passive-aggressive today.", "Ignoring warnings is a strategy. Technically.",
             "{count}. They won't read themselves."]
        case .labProblems:
            ["{count}. Off and on again is still on the table.", "Broken. Shocking, said nobody.",
             "Problems. The weekend just got planned for you."]
        case .labUnknown:
            ["No idea. The server's being mysterious.", "Unknown. Like the rent next year.",
             "Unknown. Checked the cable? Really checked?"]

        case .reasonDown:
            ["Offline. Have you tried actually looking at it?",
             "Gone. It'll be back when it feels like it, like the bus."]
        case .reasonContainer:
            ["Works on the maintainer's machine. Not on yours.", "It crashed. Read the logs, they won't bite."]
        case .reasonDisk:
            ["You don't need all of that. You know you don't.", "Delete something. Anything. Please."]
        case .reasonHot:
            ["Toasty. Maybe not next to the heater, then?", "Hot enough to heat the flat. Cheaper than gas, at least."]
        case .reasonLoad:
            ["Working harder than you, apparently.", "It's not slow. It's overcommitted. Like you."]
        case .reasonPower:
            ["That USB charger was never a power supply.", "Underfed, like the school budget."]
        case .reasonBackup:
            ["No backup. Bold move.", "Your data is one bad day from gone. Fun."]
        case .reasonOther:
            ["This is why the cloud costs money.", "Self-hosting: free as in free time.",
             "Fixable. By you. Today, ideally."]

        case .emptyApprovals:
            ["Nothing to approve. The agent is behaving.", "Nothing to approve. The robot is napping.",
             "Nothing to approve. Enjoy the power while it lasts."]
        case .emptyTodos:
            ["No to-dos. Who are you and what have you done?", "Empty. You'll find something to put off."]
        case .emptyDeadlines:
            ["No deadlines. Enjoy it, it never lasts.", "Nothing due. Someone planned ahead. Not you, though."]
        case .emptyParcels:
            ["No parcels. Your bank account sends its thanks.", "Nothing coming. Did online shopping finally break?"]
        case .emptySearch:
            ["Nothing found. Typo, or very niche taste?", "Nothing. Even the streaming services gave up on that one."]
        case .emptyChat:
            ["Say something. It's lonely in here.", "It knows your lab better than you do.",
             "Go on, ask. It won't judge. Much."]

        case .emptyDeals:
            ["No deals. Everyone prices like it is 2021.", "Nothing cheap. Your wallet is safe, your hobby less so."]

        case .done:
            ["Done. You're basically a sysadmin now.", "Done. Try not to break it again.",
             "Done. That was the easy part.", "Done. Quicker than a government IT project."]
        case .failed:
            ["Nope. Have you tried reading the error?", "Failed. The server has opinions."]

        case .noticeProblem:
            ["Something broke. Of course it did.", "Fresh problem, still warm."]
        case .noticeWarning:
            ["A warning. You'll ignore it, won't you?", "Something wants attention. Again."]
        case .noticeRecovered:
            ["It's back. Pretend you fixed it.", "Fixed itself. Take the credit anyway."]
        case .noticeWaiting:
            ["It won't approve itself.", "The agent has ideas again.", "A robot awaits your blessing."]

        case .noticeDeal:
            ["Cheap thing found. Try not to hoard.", "A bargain. Your wallet will not survive."]
        }
    }

    // MARK: Ultrakill

    static func ultrakill(_ place: Voice.Place) -> [String] {
        switch place {
        case .todayCalm:
            ["Nothing's broken. Enjoy it. Nothing lasts.", "All quiet. Entropy is just pacing itself.",
             "Everything works. Suspicious, in this economy.", "It works. Leave it alone, you menace.",
             "Calm. Like a morgue.", "Stable. Unlike rent, inflation or the coalition.",
             "Nothing's wrong. Inflation was transitory too."]
        case .todayHeadsUp:
            ["Something's dying slowly. Like the EU's plans.", "Not dead yet. Give it time.",
             "A warning. Ignore it like the climate reports.", "Your lab is sulking. Draft the eulogy.",
             "A warning. File it in triplicate, then panic.", "Mild decay. Like infrastructure, but yours."]
        case .todayAlarm:
            ["Shit's broken. Go fix it.", "Something died. Go find the body.",
             "Time of death: just now. Cause: you.", "Another casualty of your homelab.",
             "It broke. Form a task force, then do nothing.", "Something died. No minute of silence, fix it."]
        case .todayUnknown:
            ["The lab's ignoring you. Smart lab.", "No signal. Either dead or unionising.",
             "Silence. Like the Magistrat on a Friday.", "No signal. The ÖBB calls this a short delay.",
             "Lost contact. Even Chat Control can't find it."]

        case .labAllGood:
            ["No problems. Rarer than an affordable flat in Vienna.",
             "Stable. More than any campaign promise ever managed.",
             "All good. A consultant somewhere is billing for that.",
             "All quiet. Call it deterrence and double the budget.",
             "All good. Savour it. Entropy is only on a coffee break."]
        case .labWarnings:
            ["{count}. Officially 'transitory', like inflation was.",
             "Noted, then ignored, as climate summits taught us.",
             "{count}. The EU is drafting a regulation about it.",
             "Slow decay, announced in advance. Like a pension reform.",
             "{count}. Enough for a week-long culture war."]
        case .labProblems:
            ["{count}. Form a commission. Report due in 2031.",
             "Broken. Blame the previous government, like everyone does.",
             "{count}. No bailout coming. You're not a bank.",
             "Burning. A climate summit will fly in by private jet."]
        case .labUnknown:
            ["Status unknown. Like the ministry's plan for anything.",
             "No idea how it's doing. Neither does the central bank.",
             "Unknown. Even mass surveillance couldn't tell you."]

        case .reasonDown:
            ["Gone, unlike every 'temporary' tax.", "Offline. Saving energy, as the ministry kindly suggested.",
             "Unreachable, like property management when the heating dies.",
             "{host} is gone. Its pension was never real anyway."]
        case .reasonContainer:
            ["Microservices: the outsourcing of your own failures.",
             "Restart it. Bailouts work for banks, why not for this?",
             "Dead on arrival, like every AI startup's business model."]
        case .reasonDisk:
            ["Full. Like Vienna's housing waitlist.", "No space left. The housing market sends its sympathies.",
             "Charge the files rent. It works for the property funds.",
             "Storage inflation. Transitory, the experts promise."]
        case .reasonHot:
            ["Hotter than a climate summit's private jet runway.",
             "Global warming, local edition. No summit will save it.",
             "Free heating. The energy ministry calls that a policy."]
        case .reasonLoad:
            ["Overworked and underpaid. Like everyone in this economy.", "Doing three jobs. Welcome to the gig economy.",
             "Burning cycles for nothing, like an AI hype demo.", "Slow. Still faster than the U5 construction."]
        case .reasonPower:
            ["Underpowered. Energy policy, but in miniature.",
             "Not enough current. The grid operator calls that 'stable'.",
             "Rationed power. The energy crisis never really ended."]
        case .reasonBackup:
            ["No backup. Like the pension system.", "Your data, gone. The cloud would at least have sold it first.",
             "Failed. Even the data retention law keeps better copies."]
        case .reasonOther:
            ["Broken. Someone will hold a press conference about it.",
             "Not my department. Try the Magistrat, form B-17, in triplicate.",
             "Officially a 'temporary disruption'. Ask the ÖBB how that ends.",
             "The market will fix it. It won't."]

        case .emptyApprovals:
            ["Nothing to approve. Go be productive. Or don't.", "Nothing to approve. The bot gave up on you.",
             "Nothing to approve. Parliament calls that a productive week.",
             "Nothing to approve. The AI is following the AI Act. Probably."]
        case .emptyTodos:
            ["No to-dos. Enjoy it before the next reform adds some.",
             "Nothing to do. Ideal qualifications for a supervisory board.",
             "Empty list. Productivity culture will find you something."]
        case .emptyDeadlines:
            ["No deadlines. As binding as a climate target.",
             "Nothing due. Enjoy it, the tax office is just reloading.",
             "Nothing due. Postponed indefinitely, like the school reform."]
        case .emptyParcels:
            ["No parcels. Your bank account can breathe.", "Nothing coming. Supply chains, or self-control? Unclear.",
             "No parcels. The tech oligopoly misses your money."]
        case .emptySearch:
            ["Nothing found. Probably region-locked by a licensing cartel.",
             "No results. The algorithm has decided you don't need it.",
             "Nothing. Even the surveillance state found more.", "Nothing found. Not even a cookie banner."]
        case .emptyChat:
            ["Say something. We're all dying anyway.", "Type something. The void is listening.",
             "Ask something. It's cheaper than a consultant.", "Talk to it. It's the only AI here not raising money."]

        case .emptyDeals:
            ["No deals. Inflation got there first.", "Nothing underpriced. The invisible hand is on lunch.",
             "No bargains. Late capitalism sends its regards."]

        case .done:
            ["Done. Faster than any ministry has ever done anything.",
             "Done. No form, no stamp, no Magistrat. Revolutionary.",
             "Done. That's more delivery than the last election promised.",
             "Done. Put it in your LinkedIn bio. Everyone else would."]
        case .failed:
            ["Didn't work. File a complaint. Nobody reads them either.",
             "Failed. Call it a pilot project and ask for more funding.", "No luck. Blame the EU. Everyone else does."]

        case .noticeProblem:
            ["Something broke. Rent went up anyway.", "New corpse. Bring a shovel and a terminal.",
             "Breaking news, literally. No pundit needed."]
        case .noticeWarning:
            ["Early warning. Ignore it like the climate ones.", "A warning. Outrage cycle starts in 3, 2, 1.",
             "Something's wobbling. So is the coalition."]
        case .noticeRecovered:
            ["It recovered. Unlike housing affordability.", "Resurrected. No miracle, just a restart.",
             "Fixed itself. The free market takes the credit."]
        case .noticeWaiting:
            ["Decide. Faster than the Magistrat, ideally.", "The bot did the work. Press the button.",
             "Approve it before entropy does.", "Sign here. In triplicate, for tradition's sake.",
             "The bot asks first. Unlike the data brokers.", "Approve it. Digital ID not required. Yet."]

        case .noticeDeal:
            ["A bargain. The market blinked first.", "Underpriced. Someone forgot to be greedy.",
             "Cheap hardware. Capitalism has its moments."]
        }
    }
}
