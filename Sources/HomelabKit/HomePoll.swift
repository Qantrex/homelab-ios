import Foundation

// When Today reads Home Assistant's states, and how fresh they must be to be shown. One loop on Today (every
// `HomePoll.interval`) serves everything that reads them: the Home tiles, a Home "When it needs me" rule, the headline
// without a Companion server, and Where you are. With the Home section shown (the owner's Today) it is the same one
// request every 30 s as when the tiles polled on their own.

public enum HomePoll {
    /// Seconds between two reads while Today is open.
    public static let interval: TimeInterval = 30
    /// States older than this don't make a headline: after a while in the background, or while Home Assistant doesn't
    /// answer, Today says a grey "Home." until the next read, not hours-old facts.
    public static let fresh: TimeInterval = 2 * 60

    /// Whether Today reads Home Assistant: there is one, and something on Today needs its states. The Home section
    /// shown; Home set to "When it needs me" (and not hidden), so a tile that goes unavailable can bring it back;
    /// no Companion server selected (the headline reads Home Assistant); or Where you are set up.
    public static func shouldPoll(homeAssistant: Bool, homeShown: Bool, homeVisible: Bool, homeRule: ShowRule?,
                                  companionSelected: Bool, presenceSetUp: Bool) -> Bool {
        guard homeAssistant else { return false }
        return homeShown || (homeVisible && homeRule == .needsMe) || !companionSelected || presenceSetUp
    }

    /// Whether states read at `fetched` are recent enough to show at `now`.
    public static func isFresh(_ fetched: Date?, now: Date) -> Bool {
        guard let fetched else { return false }
        return now.timeIntervalSince(fetched) <= fresh
    }
}

extension AppModel {
    /// Whether Today reads Home Assistant now (`HomePoll.shouldPoll`), with `shown` the sections Today shows.
    public func pollsHome(shown: [TodaySection]) -> Bool {
        let layout = settings.todayLayout
        return HomePoll.shouldPoll(homeAssistant: homeAssistant != nil, homeShown: shown.contains(.home),
                                   homeVisible: layout.isVisible(.home), homeRule: layout.rule(for: .home),
                                   companionSelected: selected != nil, presenceSetUp: presenceSetUp)
    }

    /// The headline without a Companion server: Home Assistant at a glance from the states Today holds, read without
    /// an error and recently (`HomePoll.isFresh`); else nil, a grey "Home.".
    public func homeGlance(entities: [HAEntity], fetched: Date?, failed: Bool, now: Date) -> HomeGlance? {
        guard let ha = homeAssistant, !failed, !entities.isEmpty, HomePoll.isFresh(fetched, now: now) else { return nil }
        return HomeGlance(entities: entities, pinned: ha.pinnedEntities)
    }

    /// Whether Today checks rules against a context. Without rules and without Where you are, Today's sections are
    /// exactly `Density.sections(_:)` and nothing reads Home Assistant's states or the clock for them, so a new read
    /// every 30 s doesn't redo Today.
    public var todayNeedsContext: Bool { settings.todayLayout.rules != nil || presenceSetUp }

    /// The sections Today shows now, and the context their rules were checked against (nil when
    /// `todayNeedsContext` is false). The states and their time are only read when a context is built.
    public func todaySections(now: Date, calendar: Calendar = .current, homeEntities: () -> [HAEntity],
                              fetched: () -> Date?) -> (sections: [TodaySection], context: ShowContext?) {
        let density = settings.todayDensity
        let layout = settings.todayLayout
        guard todayNeedsContext else { return (density.sections(layout), nil) }
        let entities = homeEntities()
        let context = todayContext(now: now, calendar: calendar, homeEntities: entities,
                                   presence: presence(in: entities, fetched: fetched()))
        return (density.sections(layout, context), context)
    }
}
