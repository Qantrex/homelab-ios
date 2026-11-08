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
            "{host} answered when asked. That is all it did.",
            "Nothing to report from {host}. A good sign, in this line of work.",
            "{host} is reachable. Its owner may relax a little.",
            "Up: {host}. The dull kind of good news.",
        ]
        case .hostDown: [
            "{host} is down. A quiet exit.",
            "{host} was last checked {checked}. It did not answer.",
            "{host} is unreachable. A cable is the cheapest explanation.",
            "No sign of {host}. It may simply be resting.",
            "{host} does not answer. Silence is also a result.",
            "Nothing from {host}. It has gone quiet.",
            "{host} is unreachable, which is the polite word for it.",
        ]
        case .hostFull: [
            "{host} is {pct} full. The rest is a matter of time.",
            "{mount} on {host} is at {pct}. A tidy-up would not hurt.",
            "{host} sits at {pct} used. Something will have to give.",
            "{host} is at {pct}. There is still some room, technically.",
            "{pct} of {host} is taken. Deleting is free.",
            "Storage on {host} is {pct} used. The trend is clear.",
        ]
        case .hostHot: [
            "{temp} on {host}. It is working, visibly.",
            "{host} is at {temp}. A fan would be a kindness.",
            "{host} has reached {temp}. Comfortable for nobody.",
            "{host} reads {temp}. It would like to be somewhere cooler.",
            "{temp} on {host}. Warm, in the way of a small stove.",
            "{host} runs at {temp}. Worth a glance at the airflow.",
        ]
        case .hostBusy: [
            "{host} has a load of {load} on {cores}. Busy, but coping.",
            "Load {load} across {cores} on {host}. Hard at work.",
            "{host} is asked for more than {cores} can give: load {load}.",
            "{host} is at load {load} on {cores}. A full day's work.",
            "Load {load} on {cores}: {host} has no spare minutes.",
            "{host} carries load {load} across {cores}. Without complaint, so far.",
        ]
        case .approval: [
            "{title} waits for you. It is patient.",
            "{title} wants a yes or a no. Either will do.",
            "Proposed {age}: {title}. Still your call.",
            "{title} is still undecided. Nobody is rushing you.",
            "A decision on {title} is requested. Politely.",
            "{title} sits in the queue. Quietly, as such things do.",
            "The agent proposes {title}. You dispose.",
        ]
        case .todo: [
            "{title} is {status}. Noted.",
            "To-do {title}: {status}. Make of that what you will.",
            "{title}, {status}. Progress, of a sort.",
            "{title} is {status}. The list remains honest.",
            "Item: {title}, {status}. Recorded without comment.",
            "{title}: {status}. Such is the state of things.",
            "{status} for {title}. Nothing more to it.",
            "{title} stands at {status}. Eventually, that changes.",
        ]
        case .deadline: [
            "{title}: {when}. The clock does not negotiate.",
            "{title} is due, {when}. Not a surprise.",
            "{when} for {title}. Plenty of notice was given.",
            "{title} falls {when}. Calendars do not bend.",
            "{when} is when {title} counts. Just so you know.",
            "{title}, {when}. A fixed point in an uncertain week.",
            "{title} is marked {when}. It will not move itself.",
            "Note for {title}: {when}. That is all.",
        ]
        case .departure: [
            "Towards {towards} at {when}. The timetable says so.",
            "{towards}: {when}. Subject to the usual optimism.",
            "{line} to {towards} leaves at {when}. In theory.",
            "A service towards {towards} leaves at {when}. Punctuality varies.",
            "{when}, {towards}. Be there slightly before.",
            "{towards} is served at {when}. The platform is a matter of luck.",
            "The service to {towards} leaves {when}. Probably.",
            "{towards} at {when}. The timetable is confident, at least.",
            "Departure {when}, towards {towards}. Shoes advised.",
        ]
        case .deal: [
            "{title} is under its value. That is the whole point.",
            "{title} at {price}. Worth a look, one suspects.",
            "{off} under market for {title}. Somebody is selling cheaply.",
            "A bargain, or so the algorithm believes: {title}.",
            "{title} is cheaper than usual. Worth knowing.",
            "A price below the market for {title}. These things are rare.",
            "{title} is on offer. Check the seller before the price.",
            "The numbers favour {title} today.",
        ]
        case .download: [
            "{title} is on the list. Patience.",
            "{title} is in the downloads. Whether it is any good is another matter.",
            "{title} is {progress} done. The rest is waiting.",
            "{title} is in the queue. Bandwidth permitting.",
            "{title} is on its way, or already here.",
            "Added to the downloads: {title}. The disk was not consulted.",
            "{title} will be ready eventually.",
        ]
        case .grade: [
            "{subject}: {value}. Duly recorded.",
            "{value} in {subject}. It will do.",
            "{subject} comes in at {value}. Make of it what you will.",
            "{subject} reads {value}. The number is what it is.",
            "In {subject}: {value}. Filed under results.",
            "{value} for {subject}. Neither good nor bad, only so.",
            "A {value} in {subject} appeared. Entered as such.",
        ]
        case .news: [
            "{title}. Make of it what you will.",
            "{title}. The news cycle turns on.",
            "Headline: {title}. Nothing here needs you.",
            "{title}. The world carries on regardless.",
            "In the news: {title}. Take it in small doses.",
            "{title}. Mildly relevant, at best.",
            "Reported: {title}. The details are elsewhere.",
            "{title}. A headline, as headlines go.",
            "{title}. Someone found this worth printing.",
        ]
        case .homeTile: [
            "{name} is {state}. As far as it knows.",
            "{name}: {state}. Home Assistant says so.",
            "{name} reads {state}. The house is cooperating.",
            "{name} is {state}. No further comment.",
            "The house reports {name} as {state}.",
            "{name}: {state}. It was like that a moment ago, too.",
            "{name} states {state}. Believe it or not.",
            "At the moment {name} is {state}.",
            "{name} is {state}, according to its sensor.",
        ]
        case .homeScene: [
            "{name} ran {when}. It did what it does.",
            "The scene {name} last ran {when}.",
            "{name} was last triggered {when}.",
            "{when}: that was the last time {name} ran.",
            "Last run of {name}: {when}. Nothing since.",
            "{name} has been quiet since it ran {when}.",
            "{name} ran {when}. The lights remember.",
        ]
        case .chatReply: [
            "{words}. The agent has said its piece.",
            "{words}, delivered. Read at your leisure.",
            "A reply of {words}. Concise enough.",
            "{words}, no more and no less.",
            "The agent answered in {words}. Brevity was not the goal.",
            "{words} arrived. They are all yours.",
        ]
        case .list: [
            "{title}: {count}, all shown.",
            "{count} in {title}. Every one of them.",
            "{title} holds {count}. None hidden.",
            "{title} lists {count}. Each one is below.",
            "The whole of {title}: {count}.",
            "{count} are in {title}, and they are all shown.",
        ]
        case .server: [
            "{name} answered. The numbers are its own.",
            "From {name}, {age}. Take it as it is.",
            "{name} reports. All claims are its own.",
            "{name} is the source. Weigh it accordingly.",
            "Everything here is {name}'s word.",
            "{name} answered. What it says is its own affair.",
        ]
        case .action: [
            "{title}. It does what it says.",
            "{title} is on the list. Use it sparingly.",
            "{title}, {fields} to fill in. Manageable.",
            "{title} is available. It does as it is told.",
            "{title}: one tap, and it happens.",
            "The action {title} is ready when you are.",
            "{title} waits to be used. It has time.",
            "{title} is a button. Nothing more mysterious.",
        ]
        case .row: [
            "{title} is on the list.",
            "{title}: noted.",
            "{title} reads {value}. As reported.",
            "{title} is here, as reported.",
            "{title}: listed.",
            "A row for {title}. No more, no less.",
            "{title} appears in the list. It has its reasons.",
            "Entry: {title}. Duly shown.",
            "{title} reads {value}. That is all it says.",
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
            "{host} is up. Go on, take the credit.",
            "{host} answers. Nothing for you to fix, how dull.",
            "Still up: {host}. You must be so proud.",
            "{host} is fine. Do not jinx it.",
        ]
        case .hostDown: [
            "{host} is down. Its numbers are all blank. Convenient.",
            "{host} has left the building. Without notice.",
            "Last checked {checked}: {host} said nothing. Rude.",
            "{host} is offline. Have you tried looking at it?",
            "{host} is gone. Convenient timing, as always.",
            "Nothing from {host}. It probably saw the bill.",
            "{host} is down. Do something about it, or do not, as usual.",
        ]
        case .hostFull: [
            "{pct} on {host}. You hoard like it's the 90s.",
            "{host} is {pct} full. The rest is mostly duplicates, admit it.",
            "{mount} on {host} is at {pct}. Bold of you not to care.",
            "{pct} full on {host}. Nothing says commitment like hoarding.",
            "{host} has {pct} used. Delete a few things you will not watch.",
            "Storage on {host}: {pct}. You do know deleting exists.",
        ]
        case .hostHot: [
            "{host} is at {temp}. You could fry an egg. Not recommended.",
            "{temp} on {host}. Free heating, as promised.",
            "{host} runs at {temp}. Maybe open a window. For the box.",
            "{host} at {temp}. Cozy, if you are a toaster.",
            "{temp} on {host}. It is trying very hard. Poor thing.",
            "{host} reads {temp}. Maybe stop asking it to do things.",
        ]
        case .hostBusy: [
            "Load {load} on {cores}. {host} is working harder than you.",
            "{host} queues work faster than {cores} clear it: load {load}.",
            "{host} is at load {load} on {cores}. Ambition, mostly.",
            "{host} at load {load} on {cores}. It is the only one working here.",
            "Load {load} on {cores}. {host} would like a word with HR.",
            "{host} runs at load {load} on {cores}. Overachiever.",
        ]
        case .approval: [
            "A robot awaits your blessing for {title}.",
            "Asked {age}: {title}. Still no answer from you.",
            "{title} is pending. The agent is very patient. You are not.",
            "{title} still waits. You are slower than the robot.",
            "The agent asks about {title} again. Nobody is surprised.",
            "{title} needs your yes or no. It is not a riddle.",
            "Pending: {title}. Your thumb has one job.",
        ]
        case .todo: [
            "{title} is {status}. Riveting.",
            "{status}: {title}. The list judges you silently.",
            "{title} is {status}. Don't make it a project.",
            "{title} is {status}. Shocking progress.",
            "{title}, {status}. The list sighs.",
            "Status of {title}: {status}. You know what to do.",
            "{title} is {status}, and you know it.",
            "{status}: {title}. The list is not going anywhere.",
        ]
        case .deadline: [
            "{title}, {when}. Future you is going to be furious.",
            "{title} is due, {when}. Procrastination has a limit.",
            "{when} for {title}. Bold of you to relax.",
            "{title} is due {when}. Optimism is not a plan.",
            "{when} for {title}. The clock does not care about your mood.",
            "{title}, {when}. Panic scales nicely.",
            "{title} lands {when}. Start whenever. Not now, obviously.",
            "{when}: {title}. You have been warned. Again.",
        ]
        case .departure: [
            "{towards} at {when}. Run, don't walk.",
            "{towards}, {when}. Allegedly on time.",
            "The {when} to {towards}. Delays not included.",
            "{towards} at {when}. The train will not wait for your coffee.",
            "The {when} to {towards}. Brisk walking recommended.",
            "{towards}, {when}. Be early, or be philosophical.",
            "To {towards} at {when}. Late is its default mode.",
            "{when} towards {towards}. Hope is not a timetable.",
            "{towards}: {when}. Run, or at least walk with intent.",
        ]
        case .deal: [
            "{title} for {price}. You will buy it. We both know.",
            "{off} below market. {title} is either a steal or a scam.",
            "{title}. Everything has a price, apparently {price}.",
            "{title} is cheap. Cheap things have a way of being a trap.",
            "{title} has turned up under its price. Try not to gloat.",
            "{title} is cheap. Your wallet already leans in.",
            "A deal on {title}. Of course there is.",
            "{title} is under market. Restraint is a skill.",
            "{off} less for {title}. Hold your horses.",
        ]
        case .download: [
            "{title}. You haven't watched half the last batch.",
            "{title} is on the disk now. Your backlog thanks you not.",
            "{title} is {progress} done. Good things come to those who stream.",
            "{title} is coming down. Add it to the pile.",
            "More {title} for the backlog. Splendid.",
            "{title} landed on the disk. Whether you watch it is another story.",
            "{title} is queued. Your free time is not.",
        ]
        case .grade: [
            "{value} in {subject}. Your parents will have thoughts.",
            "{subject}, {value}. The teacher has opinions too.",
            "{subject} at {value}. Not a disaster, not a flex.",
            "{value} in {subject}. Frame it or forget it.",
            "{subject}: {value}. Not nothing, not much either.",
            "{subject} says {value}. Do with that what you will.",
            "Here is your {value} in {subject}. Try to look surprised.",
        ]
        case .news: [
            "{title}. Doomscroll responsibly.",
            "{title}. Outrage costs nothing.",
            "{title}. Another day, another crisis.",
            "{title}. Somebody had to write it.",
            "{title}. Another headline you will forget by lunch.",
            "{title}. The world is fine. Probably.",
            "{title}. Read it or do not, it will happen anyway.",
            "{title}. Hot take loading.",
            "{title}. Today's installment of everything.",
        ]
        case .homeTile: [
            "{name} is {state}. The house is smarter than you.",
            "{name}, {state}. Smart home, dumb flat.",
            "{state} on {name}. Thrilling.",
            "{name} is {state}. Wow.",
            "{name}, {state}. The flat has opinions.",
            "The house says {name} is {state}. Trust it.",
            "{name} is {state}. You could check, but why.",
            "{state} on {name}. As if you did not know.",
            "{name}: {state}. Smart enough to tell, too dumb to fix.",
        ]
        case .homeScene: [
            "{name} ran {when}. Atmosphere on demand.",
            "You triggered {name} {when}. Feel the ambience.",
            "{name} last ran {when}. The mood has long since gone.",
            "Scene {name}: {when}. Cinema, apparently.",
            "{name} ran {when}. Candlelight sold separately.",
            "The last time for {name}: {when}. Romantic, sure.",
            "{name} ran {when}. Nobody else saw it.",
        ]
        case .chatReply: [
            "{words}. It could have said less. So could you.",
            "{words} of confidence, none of it verified.",
            "The robot wrote {words}. You will skim.",
            "{words} of robot opinion.",
            "The agent wrote {words}. Of course it did.",
            "{words}. You will read the first and nod.",
        ]
        case .list: [
            "{title} has {count}. No folds, no mercy.",
            "All {count} of {title}. You asked for this.",
            "{count} in {title}, all of them out.",
            "{title} holds {count}. Enjoy the scroll.",
            "{count} in {title}, all on display.",
            "Here is {title}: {count}, no filter.",
        ]
        case .server: [
            "{name} spoke {age}. Believe it or not.",
            "{name} says all this with a straight face.",
            "Everything here comes from {name}. Blame it.",
            "{name} is behind all of this. Take it up with them.",
            "That all comes from {name}. It swears it is true.",
            "{name} answered {age}. Eventually.",
        ]
        case .action: [
            "{title}. Pressing it makes you feel in control.",
            "{title} is one tap away from regret.",
            "{title}, with {fields}. Fill them in, hero.",
            "{title}. Press it, see what happens.",
            "{title} is ready. Your move, genius.",
            "{title}: a tap away from consequences.",
            "Tap {title} if you dare. It is mostly fine.",
            "{title} is waiting. So are the consequences.",
        ]
        case .row: [
            "{title}, for the record.",
            "{title} is {value}. Fascinating.",
            "{title} has a row of its own. Lucky it.",
            "{title}. Thrilling stuff.",
            "{title} is here. Happy now?",
            "A row for {title}. You asked for this.",
            "{title}: {value}. Compelling.",
            "{title}, front and centre. For some reason.",
            "Look, {title}. A row.",
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
            "{host} is up. Don't thank me, thank luck.",
            "{host} answers like a good little server. For now.",
            "{host} lives. Try not to fuck it up today.",
            "No fire on {host}. Pure fucking luck.",
        ]
        case .hostDown: [
            "{host} is dead. Surprise, you built it.",
            "{host} is down and every one of its numbers is a fucking blank.",
            "Checked {checked} and {host} stayed silent. Bastard.",
            "{host} is gone. Shocking, said nobody who has seen your cables.",
            "{host} is offline. Go and look at it, you coward.",
            "{host} is down and so is your uptime pride, you bastard.",
            "Nothing from {host}. Dead as a doornail, damn it.",
            "{host} is silent. Go kick the damn cable.",
        ]
        case .hostFull: [
            "{host} is {pct} full. You hoard like a damn dragon.",
            "{pct} used on {host}. Delete some shit already.",
            "{mount} on {host}: {pct}. Terabytes of crap, lovingly kept.",
            "{host} at {pct}. Housing prices, but for fucking bytes.",
            "{pct} full. Buy a bigger disk or grow a spine.",
            "{host} at {pct}. Hoarding bloody everything, as ever.",
            "{pct} on {host}. Clean it up or drown in your own shit.",
            "{host} is nearly full at {pct}. Congratulations, you pack rat.",
        ]
        case .hostHot: [
            "{host} is at {temp}. It's cooking, and not in a good way.",
            "{temp} on {host}. Hot as hell, and you did nothing.",
            "{host} hits {temp}. Fix the damn airflow.",
            "{temp}. {host} is a bloody space heater with delusions.",
            "{host} reads {temp}. Open a goddamn window, you damn fool.",
            "{temp} on {host}. It's roasting, and so is your cooling plan.",
            "{host} at {temp}. A fucking oven with a network card.",
        ]
        case .hostBusy: [
            "Load {load} on {cores}. {host} is drowning in its own jobs.",
            "{host} is at load {load} on {cores}. Do something, you slacker.",
            "Load {load}, {cores}. {host} works like a damn intern.",
            "{host} at load {load} on {cores}. Overcommitted, like your whole life.",
            "{host} is at load {load} on {cores}. It works harder than you ever did.",
            "Load {load} on {cores}. {host} is begging for mercy, damn it.",
            "{host} grinds at load {load} on {cores}. Feed it less shit.",
        ]
        case .approval: [
            "{title} needs a decision, you indecisive fuck.",
            "Approve {title} or deny it. Doing nothing is not a plan.",
            "{title}, asked {age}, still unanswered. Shit service.",
            "{title} is waiting on you. Even a ministry answers faster.",
            "{title} waits. Say yes, say no, say anything, damn it.",
            "The bot asks about {title}. Answer it, you coward.",
            "{title} is stuck on your lazy damn thumb.",
            "Decide on {title}, you dithering idiot.",
        ]
        case .todo: [
            "{title} is {status}. Wake the fuck up.",
            "{title}: {status}. Another monument to your procrastination.",
            "{title} is {status}. Nobody gives a damn but you.",
            "{title}, {status}. Whatever you say, boss.",
            "{title} is {status}. Do something, you sloth.",
            "{title}: {status}. A little bloody effort is free.",
            "{status} for {title}. Your list judges you, and so do I.",
            "{title} is {status}. Pathetic, but honest.",
            "{title}, {status}. Bullshit excuses are not a task manager.",
        ]
        case .deadline: [
            "{title}: {when}. Move your damn ass.",
            "{title}, {when}. Deadlines don't give a shit about your mood.",
            "{when}: {title}. Panic is a legitimate strategy, apparently.",
            "{title} lands {when}. Good luck, you procrastinating wreck.",
            "{title} lands {when}. Hurry the fuck up.",
            "{when} for {title}. Tick tock, you procrastinating clown.",
            "{title}, {when}. Deadlines eat the slow, damn it.",
            "{title} is due {when}. Your excuses are shit, everyone knows.",
            "{when}: {title}. Get moving, damn you.",
        ]
        case .departure: [
            "{towards} at {when}. Move your ass or walk.",
            "{when} to {towards}. Late by default, like the whole damn network.",
            "{towards}: {when}. The timetable is a bloody work of fiction.",
            "Towards {towards} at {when}. Don't miss it, you slowpoke.",
            "{towards} at {when}. Sprint, you slug.",
            "The {when} to {towards}. Miss it and you walk, genius.",
            "{towards}, {when}. Public transport is a damn lottery.",
            "To {towards} at {when}. Late again, like your whole damn life.",
            "{when} towards {towards}. Move your fucking feet.",
            "{towards}: {when}. The driver doesn't give a shit about you.",
            "{when} to {towards}. Another day, another bloody delay.",
        ]
        case .deal: [
            "{title} for {price}. Take my money, you'll say.",
            "{off} under market for {title}. A steal or a fucking scam.",
            "{title} is a deal, apparently. Don't fuck it up.",
            "{title} looks cheap. So does your whole plan.",
            "{title} at {price}. Your wallet is already crying.",
            "Buy {title} or keep complaining about prices.",
            "{title} is cheap as hell. Your wallet screams.",
            "{title} below market. Grab it before some other bastard does.",
            "A deal on {title}. Don't be a fucking sucker.",
            "{title} is on sale. Self-control is dead, apparently.",
        ]
        case .download: [
            "{title} again? Your backlog is a goddamn graveyard.",
            "{title} is downloaded. You won't watch it, will you?",
            "{title}: more shit for the pile.",
            "{title} is {progress} done. Faster than your life choices.",
            "{title} landed. Another file to ignore, you hoarder.",
            "{title} is coming in. Your disk groans, the poor shit.",
            "More {title}. Never watched, always saved.",
            "{title} is queued. Whatever, it's your damn bandwidth.",
        ]
        case .grade: [
            "{value} in {subject}. Mediocrity, certified.",
            "{subject}: {value}. Study less shit, learn more.",
            "{value} in {subject}. A fucking participation trophy.",
            "{subject} at {value}. The final exam is watching, you slacker.",
            "{value} in {subject}. Not great, not terrible, just shit.",
            "{subject}: {value}. Do better, you lazy sod.",
            "{subject} says {value}. The teacher isn't impressed either, damn it.",
            "{value} for {subject}. Hang it on the fridge, you star pupil.",
        ]
        case .news: [
            "{title}. The news cycle shits again.",
            "{title}. Politicians say a lot of nothing, as ever.",
            "{title}. Read it, sigh, move on.",
            "{title}. Your daily dose of fucking despair.",
            "{title}. Same old bullshit, new date.",
            "{title}. The world is on fire again, nothing new.",
            "{title}. Skim it and carry on, you doomscroller.",
            "{title}. Some idiot wrote this, some idiot reads it.",
            "{title}. Breaking news: nothing changes, damn it.",
            "{title}. Another damn headline for the pile.",
        ]
        case .homeTile: [
            "{name} is {state}. Your smart home is stupid as shit.",
            "{name}: {state}. The house spies on you, nicely.",
            "{name} reads {state}. Peak fucking modern life.",
            "{state}. {name} has nothing to say, so it says that.",
            "{name} is {state}. The house is a fucking snitch.",
            "{name}: {state}. Your smart home thinks it's smart.",
            "{name} says {state}. Thrilling as hell.",
            "{state}, says {name}. Nobody asked, it told anyway.",
            "{name} reads {state}. Peak lazy shit, controlled by phone.",
            "The damn {name} is {state}. Go touch the switch.",
        ]
        case .homeScene: [
            "{name} ran {when}. Mood lighting, you sentimental fuck.",
            "{name} last ran {when}. The vibe died long ago, damn it.",
            "Scene {name}: {when}. Fancy lights, same sad you.",
            "{name} ran {when}. Atmosphere is no personality, sod.",
            "You fired {name} {when}. Show-off, in an empty room.",
            "{when}: {name} ran. Nobody was impressed, the bastards.",
            "{name} ran {when}. Shit scene, good bulbs.",
        ]
        case .chatReply: [
            "{words} of robot waffle.",
            "{words}. You'll read the first line and nod.",
            "The bot spat out {words}. Skim it, you lazy shit.",
            "{words}, and not one of them a decision.",
            "{words} of pure bot drivel, damn it.",
            "{words}. Skim it like the lazy bastard you are.",
            "The bot babbled {words}. Answer it or ignore it, who cares.",
        ]
        case .list: [
            "{count} in {title}, and every fucking one is out.",
            "{title}: {count}. Scroll, you glutton.",
            "All {count} in {title}. Hope you're happy.",
            "{title} spills {count} onto your screen. Your choice.",
            "{title} dumps {count} on you. Deal with it, damn it.",
            "{count} in {title}. Every damn last one.",
            "All {count} of {title}, unfiltered. You wanted this shit.",
        ]
        case .server: [
            "{name} says all this shit with a straight face.",
            "From {name}, {age}. Don't blame the messenger.",
            "{name} sent every number. Complain to it, not me.",
            "All this is {name}'s fault, give or take.",
            "{name} told you all this. Blame the damn server, not me.",
            "Every number here is {name}'s. Blame the bloody box.",
            "{name} sent this, {age}. Believe it or don't, damn it.",
        ]
        case .action: [
            "{title}. Press it, you magnificent idiot.",
            "{title}: one tap from a fucking disaster.",
            "{title} has {fields}. Fill them in or don't, who cares.",
            "{title}. Your finger, your funeral.",
            "{title}. Press the damn thing.",
            "{title} is one tap from glory or disaster, damn it.",
            "{title}: a button for people who like risks, the fools.",
            "Hit {title}, you coward, or leave it.",
            "{title} sits there. Waiting. Judging, the bastard.",
        ]
        case .row: [
            "{title}. Another row of shit nobody asked for.",
            "{title}: {value}. Fucking riveting.",
            "{title} is here. So is your screen's patience.",
            "{title} shows up, because you asked for everything.",
            "{title}. Another bloody row.",
            "{title} reads {value}. Wow. Hell yes.",
            "{title} is here. So is the shit that comes with it.",
            "{title}: {value}. Make something of it, damn it.",
            "Row for {title}. Scroll on, you glutton.",
            "{title}. Nothing to see, but you asked, damn it.",
        ]
        }
    }
}
