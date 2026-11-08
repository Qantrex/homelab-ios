import Foundation

/// The remarks Hyperdetail adds next to a fact (`Hyper.remark`). Same rules as VoiceLines.swift (HyperdetailTests): a
/// full sentence within `Hyper.maxLength` once filled, distinct per personality, no markdown characters, no "Ah," /
/// "Let's" / dashes, one quick remark each, bound to the fact by a placeholder. Dry is deadpan, Snarky teases, Ultrakill
/// is harsh and profane about the owner, the lab and systems in general (never slurs, protected groups, anything
/// sexual, self-harm, real people or threats).
enum HyperLines {
    static func all(_ kind: Hyper.Kind, _ p: Personality) -> [String] {
        switch p {
        case .off: []
        case .dry: dry(kind)
        case .snarky: snarky(kind)
        case .ultrakill: ultrakill(kind)
        }
    }

    static func dry(_ kind: Hyper.Kind) -> [String] {
        switch kind {
        case .hostUp: [
            "{host} is up and answering. Nothing to add.",
            "{host} runs {containers}. None has complained.",
            "{host} was checked {checked}. It was fine then.",
            "{host} is up. Quietly, which is how one likes it.",
        ]
        case .hostDown: [
            "{host} is down. A quiet exit.",
            "{host} was last checked {checked}. It did not answer.",
            "{host} is unreachable. A cable is the cheapest explanation.",
            "No sign of {host}. It may simply be resting.",
        ]
        case .hostFull: [
            "{host} is {pct} full. The rest is a matter of time.",
            "{mount} on {host} is at {pct}. A tidy-up would not hurt.",
            "{host} sits at {pct} used. Something will have to give.",
        ]
        case .hostHot: [
            "{temp} on {host}. It is working, visibly.",
            "{host} is at {temp}. A fan would be a kindness.",
            "{host} has reached {temp}. Comfortable for nobody.",
        ]
        case .hostBusy: [
            "{host} has a load of {load} on {cores}. Busy, but coping.",
            "Load {load} across {cores} on {host}. Hard at work.",
            "{host} is asked for more than {cores} can give: load {load}.",
        ]
        case .approval: [
            "{title} waits for you. It is patient.",
            "{title} wants a yes or a no. Either will do.",
            "Proposed {age}: {title}. Still your call.",
        ]
        case .todo: [
            "{title} is {status}. Noted.",
            "To-do {title}: {status}. Make of that what you will.",
            "{title}, {status}. Progress, of a sort.",
        ]
        case .deadline: [
            "{title}: {when}. The clock does not negotiate.",
            "{title} is due, {when}. Not a surprise.",
            "{when} for {title}. Plenty of notice was given.",
        ]
        case .departure: [
            "Towards {towards} at {when}. The timetable says so.",
            "{towards}: {when}. Subject to the usual optimism.",
            "{line} to {towards} leaves at {when}. In theory.",
        ]
        case .deal: [
            "{title} is under its value. That is the whole point.",
            "{title} at {price}. Worth a look, one suspects.",
            "{off} under market for {title}. Somebody is selling cheaply.",
            "A bargain, or so the algorithm believes: {title}.",
        ]
        case .download: [
            "{title} is on the list. Patience.",
            "{title} is in the downloads. Whether it is any good is another matter.",
            "{title} is {progress} done. The rest is waiting.",
        ]
        case .grade: [
            "{subject}: {value}. Duly recorded.",
            "{value} in {subject}. It will do.",
            "{subject} comes in at {value}. Make of it what you will.",
        ]
        case .news: [
            "{title}. Make of it what you will.",
            "{title}. The news cycle turns on.",
            "Headline: {title}. Nothing here needs you.",
        ]
        case .homeTile: [
            "{name} is {state}. As far as it knows.",
            "{name}: {state}. Home Assistant says so.",
            "{name} reads {state}. The house is cooperating.",
        ]
        case .chatReply: [
            "{words}. The agent has said its piece.",
            "{words}, delivered. Read at your leisure.",
            "A reply of {words}. Concise enough.",
        ]
        case .list: [
            "{title}: {count}, all shown.",
            "{count} in {title}. Every one of them.",
            "{title} holds {count}. None hidden.",
        ]
        case .server: [
            "{name} answered. The numbers are its own.",
            "From {name}, {age}. Take it as it is.",
            "{name} reports. All claims are its own.",
        ]
        case .action: [
            "{title}. It does what it says.",
            "{title} is on the list. Use it sparingly.",
            "{title}, {fields} to fill in. Manageable.",
        ]
        case .row: [
            "{title} is on the list.",
            "{title}: noted.",
            "{title} reads {value}. As reported.",
        ]
        }
    }

    static func snarky(_ kind: Hyper.Kind) -> [String] {
        switch kind {
        case .hostUp: [
            "{host} is up. Don't thank it, it's the bare minimum.",
            "{host} runs {containers} and still answers. Show-off.",
            "Checked {checked}. {host} was fine, which is suspicious.",
            "{host} is up. Enjoy the uptime while it lasts.",
        ]
        case .hostDown: [
            "{host} is down. Its numbers are all blank. Convenient.",
            "{host} has left the building. Without notice.",
            "Last checked {checked}: {host} said nothing. Rude.",
            "{host} is offline. Have you tried looking at it?",
        ]
        case .hostFull: [
            "{pct} on {host}. You hoard like it's the 90s.",
            "{host} is {pct} full. The rest is mostly duplicates, admit it.",
            "{mount} on {host} is at {pct}. Bold of you not to care.",
        ]
        case .hostHot: [
            "{host} is at {temp}. You could fry an egg. Not recommended.",
            "{temp} on {host}. Free heating, as promised.",
            "{host} runs at {temp}. Maybe open a window. For the box.",
        ]
        case .hostBusy: [
            "Load {load} on {cores}. {host} is working harder than you.",
            "{host} queues work faster than {cores} clear it: load {load}.",
            "{host} is at load {load} on {cores}. Ambition, mostly.",
        ]
        case .approval: [
            "A robot awaits your blessing for {title}.",
            "Asked {age}: {title}. Still no answer from you.",
            "{title} is pending. The agent is very patient. You are not.",
        ]
        case .todo: [
            "{title} is {status}. Riveting.",
            "{status}: {title}. The list judges you silently.",
            "{title} is {status}. Don't make it a project.",
        ]
        case .deadline: [
            "{title}, {when}. Future you is going to be furious.",
            "{title} is due, {when}. Procrastination has a limit.",
            "{when} for {title}. Bold of you to relax.",
        ]
        case .departure: [
            "{towards} at {when}. Run, don't walk.",
            "{towards}, {when}. Allegedly on time.",
            "The {when} to {towards}. Delays not included.",
        ]
        case .deal: [
            "{title} for {price}. You will buy it. We both know.",
            "{off} below market. {title} is either a steal or a scam.",
            "{title}. Everything has a price, apparently {price}.",
            "{title} is cheap. Cheap things have a way of being a trap.",
            "{title} has turned up under its price. Try not to gloat.",
        ]
        case .download: [
            "{title}. You haven't watched half the last batch.",
            "{title} is on the disk now. Your backlog thanks you not.",
            "{title} is {progress} done. Good things come to those who stream.",
        ]
        case .grade: [
            "{value} in {subject}. Your parents will have thoughts.",
            "{subject}, {value}. The teacher has opinions too.",
            "{subject} at {value}. Not a disaster, not a flex.",
        ]
        case .news: [
            "{title}. Doomscroll responsibly.",
            "{title}. Outrage costs nothing.",
            "{title}. Another day, another crisis.",
        ]
        case .homeTile: [
            "{name} is {state}. The house is smarter than you.",
            "{name}, {state}. Smart home, dumb flat.",
            "{state} on {name}. Thrilling.",
        ]
        case .chatReply: [
            "{words}. It could have said less. So could you.",
            "{words} of confidence, none of it verified.",
            "The robot wrote {words}. You will skim.",
        ]
        case .list: [
            "{title} has {count}. No folds, no mercy.",
            "All {count} of {title}. You asked for this.",
            "{count} in {title}, all of them out.",
        ]
        case .server: [
            "{name} spoke {age}. Believe it or not.",
            "{name} says all this with a straight face.",
            "Everything here comes from {name}. Blame it.",
        ]
        case .action: [
            "{title}. Pressing it makes you feel in control.",
            "{title} is one tap away from regret.",
            "{title}, with {fields}. Fill them in, hero.",
        ]
        case .row: [
            "{title}, for the record.",
            "{title} is {value}. Fascinating.",
            "{title} has a row of its own. Lucky it.",
        ]
        }
    }

    static func ultrakill(_ kind: Hyper.Kind) -> [String] {
        switch kind {
        case .hostUp: [
            "{host} is up. Miracles happen, even in your shit lab.",
            "{host} carries {containers} and hasn't collapsed. Not your doing.",
            "Checked {checked} and {host} was fine. Fuck knows how.",
            "{host} is up. Don't get fucking used to it.",
            "{host} answers. More than any damn ministry hotline does.",
        ]
        case .hostDown: [
            "{host} is dead. Surprise, you built it.",
            "{host} is down and every one of its numbers is a fucking blank.",
            "Checked {checked} and {host} stayed silent. Bastard.",
            "{host} is gone. Shocking, said nobody who has seen your cables.",
            "{host} is offline. Go and look at it, you coward.",
        ]
        case .hostFull: [
            "{host} is {pct} full. You hoard like a damn dragon.",
            "{pct} used on {host}. Delete some shit already.",
            "{mount} on {host}: {pct}. Terabytes of crap, lovingly kept.",
            "{host} at {pct}. Housing prices, but for fucking bytes.",
            "{pct} full. Buy a bigger disk or grow a spine.",
        ]
        case .hostHot: [
            "{host} is at {temp}. It's cooking, and not in a good way.",
            "{temp} on {host}. Hot as hell, and you did nothing.",
            "{host} hits {temp}. Fix the damn airflow.",
            "{temp}. {host} is a bloody space heater with delusions.",
        ]
        case .hostBusy: [
            "Load {load} on {cores}. {host} is drowning in its own jobs.",
            "{host} is at load {load} on {cores}. Do something, you slacker.",
            "Load {load}, {cores}. {host} works like a damn intern.",
            "{host} at load {load} on {cores}. Overcommitted, like your whole life.",
        ]
        case .approval: [
            "{title} needs a decision, you indecisive fuck.",
            "Approve {title} or deny it. Doing nothing is not a plan.",
            "{title}, asked {age}, still unanswered. Shit service.",
            "{title} is waiting on you. Even a ministry answers faster.",
        ]
        case .todo: [
            "{title} is {status}. Wake the fuck up.",
            "{title}: {status}. Another monument to your procrastination.",
            "{title} is {status}. Nobody gives a damn but you.",
            "{title}, {status}. Whatever you say, boss.",
        ]
        case .deadline: [
            "{title}: {when}. Move your damn ass.",
            "{title}, {when}. Deadlines don't give a shit about your mood.",
            "{when}: {title}. Panic is a legitimate strategy, apparently.",
            "{title} lands {when}. Good luck, you procrastinating wreck.",
        ]
        case .departure: [
            "{towards} at {when}. Move your ass or walk.",
            "{when} to {towards}. Late by default, like the whole damn network.",
            "{towards}: {when}. The timetable is a bloody work of fiction.",
            "Towards {towards} at {when}. Don't miss it, you slowpoke.",
        ]
        case .deal: [
            "{title} for {price}. Take my money, you'll say.",
            "{off} under market for {title}. A steal or a fucking scam.",
            "{title} is a deal, apparently. Don't fuck it up.",
            "{title} looks cheap. So does your whole plan.",
            "{title} at {price}. Your wallet is already crying.",
            "Buy {title} or keep complaining about prices.",
        ]
        case .download: [
            "{title} again? Your backlog is a goddamn graveyard.",
            "{title} is downloaded. You won't watch it, will you?",
            "{title}: more shit for the pile.",
            "{title} is {progress} done. Faster than your life choices.",
        ]
        case .grade: [
            "{value} in {subject}. Mediocrity, certified.",
            "{subject}: {value}. Study less shit, learn more.",
            "{value} in {subject}. A fucking participation trophy.",
            "{subject} at {value}. The Matura is watching, you slacker.",
        ]
        case .news: [
            "{title}. The news cycle shits again.",
            "{title}. Politicians say a lot of nothing, as ever.",
            "{title}. Read it, sigh, move on.",
            "{title}. Your daily dose of fucking despair.",
        ]
        case .homeTile: [
            "{name} is {state}. Your smart home is stupid as shit.",
            "{name}: {state}. The house spies on you, nicely.",
            "{name} reads {state}. Peak fucking modern life.",
            "{state}. {name} has nothing to say, so it says that.",
        ]
        case .chatReply: [
            "{words} of robot waffle.",
            "{words}. You'll read the first line and nod.",
            "The bot spat out {words}. Skim it, you lazy shit.",
            "{words}, and not one of them a decision.",
        ]
        case .list: [
            "{count} in {title}, and every fucking one is out.",
            "{title}: {count}. Scroll, you glutton.",
            "All {count} in {title}. Hope you're happy.",
            "{title} spills {count} onto your screen. Your choice.",
        ]
        case .server: [
            "{name} says all this shit with a straight face.",
            "From {name}, {age}. Don't blame the messenger.",
            "{name} sent every number. Complain to it, not me.",
            "All this is {name}'s fault, give or take.",
        ]
        case .action: [
            "{title}. Press it, you magnificent idiot.",
            "{title}: one tap from a fucking disaster.",
            "{title} has {fields}. Fill them in or don't, who cares.",
            "{title}. Your finger, your funeral.",
        ]
        case .row: [
            "{title}. Another row of shit nobody asked for.",
            "{title}: {value}. Fucking riveting.",
            "{title} is here. So is your screen's patience.",
            "{title} shows up, because you asked for everything.",
        ]
        }
    }
}
