import Foundation

/// The templates. Rules: one line on a 5.4" phone once filled (90 characters with the longest values), the fact's
/// values in every one, no "Ah,", "Well, well", "Oh look", "Let's" or em-dashes. Each reads like one quick remark
/// about the fact, not like a template: no setup without a punchline, no sentence pattern repeated from line to line.
///
/// Dry understates. Snarky teases the owner and the hardware and pokes at everyday politics. Ultrakill (owner,
/// 2026-11-09: "the word has to hold a special place") is a different tier: harsh, profane, over the top, merciless
/// about the owner and the lab, with satire of politics and current events in general terms. It mocks the owner,
/// ideas, institutions and systems; never slurs, nothing about protected characteristics, nothing sexual, no
/// self-harm, no real private people, no named public figures, no threats (TakeTests enforces a banned-word list).
enum TakeLines {
    static func all(_ kind: Take.Fact.Kind, _ p: Personality) -> [String] {
        switch p {
        case .off: []
        case .dry: dry(kind)
        case .snarky: snarky(kind)
        case .ultrakill: ultrakill(kind)
        }
    }

    // MARK: Dry: deadpan, British understatement.

    static func dry(_ kind: Take.Fact.Kind) -> [String] {
        switch kind {
        case .hostDown: [
            "{host} isn't answering.",
            "{host} has gone quiet. Rude, but not unheard of.",
            "Nothing from {host}. Someone may want to look.",
            "{host} left the network without saying goodbye.",
            "{host} is down. It had a good run.",
        ]
        case .container: [
            "{container} on {host} is {state}. Not ideal.",
            "{host} reports {container} as {state}. A restart usually helps.",
            "{container} is {state} on {host}. One for after the coffee.",
            "{container} ({state}) on {host}. It happens.",
            "{host} would like it known that {container} is {state}.",
            "{container} on {host}: {state}. Accurately reported, one assumes.",
        ]
        case .disk: [
            "{host} is {pct} full. Time to let something go.",
            "{mount} on {host} is at {pct}. Getting there.",
            "{pct} used on {host}. Deleting things remains an option.",
            "{host}'s disk is at {pct}. The free space is mostly theoretical.",
            "{host} at {pct}. The downloads folder is the usual suspect.",
            "{mount} on {host}: {pct}. Not a crisis yet.",
        ]
        case .hot: [
            "{host} is at {temp}. Warm, for a computer.",
            "{temp} on {host}. Airflow might be worth a thought.",
            "{host} reads {temp}. Not one to hold.",
            "{host} at {temp}, a bit toastier than recommended.",
        ]
        case .load: [
            "{host} has a load of {load} on {cores}. Busy.",
            "Load {load} on {host}'s {cores}. Something is working hard.",
            "{host} is asking more of {cores} than they have: load {load}.",
            "{host} at load {load} on {cores}. Mostly queueing, one suspects.",
        ]
        case .power: [
            "{host} reports {flag}. The power supply has opinions.",
            "{flag} on {host}. A better cable rarely hurts.",
            "{host}: {flag}. Electricity, just not enough of it.",
            "{host} notes {flag}. Not dramatic, not great.",
        ]
        case .backupFailed: [
            "{host}'s backup failed. Best not to need it today.",
            "The backup on {host} didn't succeed. Worth another go.",
            "{host}: backup failed. Everything is fine until it isn't.",
            "{host} failed its backup, quietly, which is the worst way.",
        ]
        case .problem: [
            "{text}. Noted.",
            "{host} mentions: {text}. Probably worth a look.",
            "{text}. Not the end of the world, not nothing.",
            "{text}. It won't fix itself.",
            "{host} reports: {text}. Mildly inconvenient.",
            "{text}. One for the list.",
        ]
        case .overdue: [
            "{todos} overdue. The oldest is {title}.",
            "{title} is overdue, plus {more}.",
            "{todos} past due. {title} has waited longest.",
            "Overdue: {todos}, led by {title}.",
            "{title} and {more} are past due.",
        ]
        case .deadline: [
            "{title} is due {when}.",
            "{when}: {title}. It won't move.",
            "{title}, due {when}. Plan accordingly.",
            "{title} is due {when}. Deadlines rarely reconsider.",
            "A reminder that {title} is due {when}.",
        ]
        case .waiting: [
            "{actions} waiting for a yes or a no.",
            "{actions} awaiting your decision, first up {first}.",
            "The agent proposes {first}. {actions} waiting in all.",
            "{actions} to approve, or not. Your call.",
            "{actions} on the desk.",
            "{actions} pending, and the agent is already impatient.",
        ]
        case .parcel: [
            "{title} is out for delivery. Someone should be in.",
            "{title} is on the van today.",
            "{title} arrives today, if the courier agrees.",
            "Out for delivery: {title}. Listen for the door.",
        ]
        case .allFine: [
            "{machines} up, {containers} running. Nothing to report.",
            "{machines} up and answering.",
            "{machines} up. {quiet} is barely awake.",
            "{containers} running across {machines}. Remarkably dull.",
            "Everything answers: {machines}, {containers}.",
            "{quiet} is the calmest of {machines}.",
            "{machines} up. Nothing is on fire, which is the main thing.",
            "{containers} running, none of them complaining. Unusual.",
        ]
        }
    }

    // MARK: Snarky: sarcastic, teases the hardware and the owner's choices, pokes at everyday politics.

    static func snarky(_ kind: Take.Fact.Kind) -> [String] {
        switch kind {
        case .hostDown: [
            "{host} is offline. Did the vacuum unplug it again?",
            "{host} stopped answering. Probably sulking about its SD card.",
            "{host} is down. Off and on again is technically a plan.",
            "{host} ghosted you. Most things you plug in eventually do.",
            "No ping from {host}. Very minimalist.",
            "{host} is gone. Faster than the Magistrat ever answered anything.",
        ]
        case .container: [
            "{container} on {host} is {state}. You never update it, do you?",
            "{container} is {state} on {host}. Trying compose up and hoping?",
            "{container} on {host}: {state}. All that YAML for this.",
            "{host} says {container} is {state}. You are the help desk now.",
            "{container} is {state}, and {host} insists it wasn't its fault.",
            "{container} on {host} is {state}. Works on the maintainer's machine.",
            "{container} is {state} on {host}. Draft the obituary, keep it short.",
        ]
        case .disk: [
            "{host} is {pct} full. Those Linux ISOs won't delete themselves.",
            "{mount} on {host} hits {pct}. Hoarding is a hobby, apparently.",
            "{host} at {pct}. You won't rewatch all of that. Nobody does.",
            "{pct} on {host}. Another drive, or some honesty about your watchlist?",
            "{host} sits at {pct}. A bigger disk only moves the problem.",
            "{mount} on {host}: {pct}. Fuller than the waiting list for a council flat.",
            "{host} is {pct} full. Streaming costs 10 euros. Pride costs more.",
        ]
        case .hot: [
            "{host} hits {temp}. Great for the heating bill, rough on the hardware.",
            "{temp} on {host}. Putting it in a cupboard was a bold choice.",
            "{host} is at {temp}. The heatsink is mostly decorative, isn't it?",
            "{host} at {temp}. A fan costs less than a new board.",
            "{temp} on {host}. Free heating. The energy ministry calls that policy.",
        ]
        case .load: [
            "Load {load} on {cores}. {host} is doing its best, which isn't much.",
            "{host} at load {load} with {cores}. Transcoding 4K on a toaster again?",
            "{host}: load {load}, {cores}. Some container thinks it's a miner.",
            "{host} has load {load} on {cores}. It's trying. Bless.",
            "Load {load} on {host}'s {cores}. Overcommitted, like you.",
        ]
        case .power: [
            "{host} reports {flag}. That phone charger was never a real PSU.",
            "{flag} on {host}. Running on vibes and a dodgy cable.",
            "{host}: {flag}. Ten euros saved on the PSU, well spent.",
            "{host} reports {flag}. Powered by a USB port and optimism.",
            "{flag} on {host}. Underfed, like the school budget.",
        ]
        case .backupFailed: [
            "{host}'s backup failed. RAID is not a backup, as you'll recall.",
            "Backup failed on {host}. Living dangerously, are we?",
            "{host}: backup failed. Schrödinger's data, now with fewer copies.",
            "{host}'s backup failed. Feeling lucky?",
        ]
        case .problem: [
            "{text}. Didn't see it coming? Everyone else did.",
            "{host} says: {text}. Self-hosting is so freeing.",
            "{text}. Just as the docs predicted.",
            "{text}. Cheaper than the cloud, they said.",
            "{host} has a complaint: {text}.",
            "{text}. Another weekend project, then.",
            "{text}. The AI Act covers this. Nobody read it.",
        ]
        case .overdue: [
            "{todos} overdue. {title} has been patient. Unlike me.",
            "{title} is overdue, plus {more}. Procrastination: going great.",
            "{todos} overdue, oldest {title}. Future you will be furious.",
            "{title} is overdue, and {more} with it. The lab is fine. You aren't.",
            "Overdue: {todos}. {title} is a lifestyle now.",
            "{title} is overdue, plus {more}. Run like a government project.",
        ]
        case .deadline: [
            "{title} is due {when}. Leaving it this late was a choice.",
            "{title}: due {when}. The servers can wait. This can't.",
            "{when}: {title}. Better start pretending you've started.",
            "{title} due {when}. Panic is a valid workflow, I suppose.",
            "{title} is due {when}. Tinkering doesn't count as progress.",
            "{title} is due {when}. Unlike election promises, this one gets checked.",
        ]
        case .waiting: [
            "{actions} waiting. The agent did the thinking, you just press a button.",
            "{actions} pending. It won't approve itself. It tried.",
            "{actions} waiting, starting with {first}. Live a little.",
            "{actions} waiting on you. Bottleneck found.",
            "{actions} queued. The robot is ready. The human is scrolling.",
            "{actions} to approve. Automation, with extra steps.",
            "{actions} waiting. Even the EU passes regulations faster.",
        ]
        case .parcel: [
            "{title} is out for delivery. Another thing to plug in and never document.",
            "{title} lands today. Don't tell anyone how much it cost.",
            "{title} is out for delivery. Clear a shelf. Or a desk. Or the floor.",
            "Out for delivery: {title}. The courier will definitely ring. Definitely.",
            "{title} arrives today. Your bank account requested a day off.",
        ]
        case .allFine: [
            "{machines} up, {containers} running. Suspicious. What are they planning?",
            "{machines} up and nothing's broken. Don't touch anything.",
            "{containers} running and not one is crying. Enjoy it.",
            "{quiet} is idling. {machines} up, and they mostly nap.",
            "{machines} up. Go outside. The lab will cope.",
            "{machines} up, zero drama. You must have stopped tinkering.",
            "{containers} on {machines}, all working. Write down what you did.",
            "{machines} up, burning watts to save a streaming subscription.",
            "{containers} running. Every single one essential, I'm sure.",
            "{machines} up. More stable than any campaign promise.",
        ]
        }
    }

    // MARK: Ultrakill: the far end. Harsh, profane, absurd, merciless about the owner and the lab; satire of
    // politics and the news cycle in general terms. Never: slurs, jokes demeaning people for who they are
    // (ethnicity, nationality, religion, gender, sexuality, disability), anything sexual, self-harm, real
    // people, threats. The facts stay plain; the insults land on the owner, the hardware and the system.

    static func ultrakill(_ kind: Take.Fact.Kind) -> [String] {
        switch kind {
        case .hostDown: [
            "{host} is dead. You killed it with neglect, you fucking clown.",
            "{host} is down. Funeral at noon, attendance: you, loser.",
            "{host} stopped answering. Smart. I'd ignore your dumb ass too.",
            "{host} is offline. Your whole lab is a hostage situation without a ransom.",
            "{host} went dark. Your shitty ISP has better uptime, and it's a monopoly.",
            "{host} is gone. Fix it, you tinkering gremlin, or cry in the cupboard.",
            "{host} died to end your hobby. Honour its sacrifice, reboot it.",
            "{host} is down. Fucking brilliant. Reboot it, numpty.",
            "{host} is unreachable. The Magistrat answers faster, and they don't answer.",
        ]
        case .container: [
            "{container} on {host} is {state}. 400 lines of YAML, for nothing.",
            "{container} is {state} on {host}. You never read a changelog, did you?",
            "{container} on {host}: {state}. You reinvented fucking downtime.",
            "{host} reports {container} {state}. Prune the whole stack, fuckwit.",
            "{container} is {state} on {host}. A drunk raccoon runs this better.",
            "{container} on {host} is {state}. Fix it, you YAML-addled prick.",
            "{container} is {state} on {host}. Sunday ruined. Congrats, arsehole.",
            "{container} on {host} is {state}. Nobody asked for this, arsehole.",
        ]
        case .disk: [
            "{host} is {pct} full. Of pirated crap you'll never watch, you hoarder.",
            "{mount} on {host} at {pct}. That's hoarding with a power bill, dumbass.",
            "{pct} on {host}. Delete something or I will. Starting with your taste.",
            "{host} at {pct}. You'll be dead before you watch half of that.",
            "{host} is {pct} full. Fuller than your calendar is empty, loser.",
            "{mount} on {host}: {pct}. Buy a disk, you bastard, or delete the Shrek rips.",
            "{host} at {pct}. Hoarding like a dragon: no gold, no cave, just shit.",
        ]
        case .hot: [
            "{host} is at {temp}. Fucking cupboard. You built an oven with a hobby.",
            "{temp} on {host}. Self-heating homelab. Too cheap for gas, prick.",
            "{host} hits {temp}. Hot enough to fry an egg, and you'd burn that too.",
            "{host} at {temp}. Climate change, cupboard edition. No summit saves this shit.",
            "{temp} on {host}. Buy a fan, you cheap bastard.",
            "{host} is at {temp}. Not on fire yet. Give your cable management time.",
            "{host} hits {temp}. Hell is a cupboard with a Raspberry Pi in it.",
        ]
        case .load: [
            "{host} at load {load} on {cores}. It works harder than you ever did, wanker.",
            "Load {load} on {cores}. {host} is carrying your bad ideas.",
            "{host}: load {load}, {cores}. Overworked, underpaid. A damn shame.",
            "{host} has load {load} on {cores}. Some shit container mines coins for nobody.",
            "Load {load} on {host} ({cores}). A crypto bro would call this a business plan.",
            "{host}: load {load} on {cores}. The poor thing does your whole team's job.",
            "{host} at load {load} on {cores}. It's a homelab, not a damn start-up.",
        ]
        case .power: [
            "{host} reports {flag}. A phone charger and a prayer. Pathetic.",
            "{flag} on {host}. You starve a Pi like it owes you rent.",
            "{host}: {flag}. Cheap PSU, cheap results, cheap owner.",
            "{host}: {flag}. Running on austerity. Brussels approves.",
            "{flag} on {host}. Ten euros saved, data lost. Maths, genius.",
            "{host} reports {flag}. Feed it properly, you stingy bastard.",
        ]
        case .backupFailed: [
            "{host}'s backup failed. One bad sector and your whole life is gone. Enjoy.",
            "Backup failed on {host}. RAID isn't a backup. Neither is hope, dumbass.",
            "{host}: backup failed. Your photos are one coin flip from gone, genius.",
            "{host}'s backup failed. Self-hosted data loss. Very sovereign, very fucking dumb.",
            "{host}'s backup failed. Even the tax office keeps better records than you.",
            "{host} botched its backup. Fucking brilliant. Hope you like amnesia.",
            "{host}'s backup failed. Should've let a data broker keep a copy.",
        ]
        case .problem: [
            "{text}. Shit's broken, and the culprit is you.",
            "{host}: {text}. Another empire falls. Yours.",
            "{text}. Self-hosting is a cope, and here's the receipt.",
            "{host}: {text}. Congratulations, fuckwit.",
            "{text}. Big Tech at least has a status page.",
            "{text}. Your homelab is a tantrum with a power cable.",
            "{text}. Nobody's coming. Your lab, your fucking mess.",
            "{text}. Fix it or sell it to some other dumbass.",
        ]
        case .overdue: [
            "{todos} overdue. {title} first. Servers outwork you, lazy shit.",
            "{title} is overdue, plus {more}. Procrastination, professional grade.",
            "{todos} overdue, oldest {title}. Do the damn thing, sloth.",
            "Overdue: {todos}. {title} will be on your tombstone.",
            "{title} is overdue, plus {more}. Parliament gets more done.",
            "{todos} overdue, oldest {title}. But sure, go tweak the Nginx config.",
            "{title} is overdue and so are {more}. Your discipline is a rumour.",
        ]
        case .deadline: [
            "{title} is due {when}. Do it, you procrastinating wanker.",
            "{when}: {title}. The homelab can wait. Your future can't, dumbass.",
            "{title}, due {when}. Death, taxes and this. Only one is your fault.",
            "{title} is due {when}. The Magistrat won't take your shit excuses.",
            "{title} due {when}. Panic now, you prick. It's cheaper than later.",
            "{title} is due {when}. Stop optimising your lab and fucking start.",
        ]
        case .waiting: [
            "{actions} waiting. The bot did the work. Just click, try not to fuck it up.",
            "{actions} pending. Late-stage capitalism at home, you as middle manager.",
            "{actions} waiting, first up: {first}. Decide before entropy does.",
            "{actions} waiting on you. The slowest part of this homelab is you, dumbass.",
            "{actions} to approve. The AI hype was real. Your reaction time isn't.",
            "{actions} pending. Approve the shit. Nobody's watching, it's not LinkedIn.",
            "{actions} waiting. A Magistrat clerk answers faster than you.",
            "{actions} waiting. You doomscrolled past all of them, didn't you?",
        ]
        case .parcel: [
            "{title} is out for delivery. Your bank account has requested a funeral.",
            "Out for delivery: {title}. Stay home. You weren't going anywhere anyway.",
            "{title} comes today. Hide it from whoever pays the damn electricity bill.",
            "{title} arrives today. More useless shit to outlive you in a drawer.",
            "{title} is on the van. Miss the bell and enjoy pickup-point purgatory.",
            "{title} arrives today. Shipped round the planet to save two euros. Green.",
            "{title} arrives today. A fool and his money, delivered between 9 and 18.",
        ]
        case .allFine: [
            "{machines} up, {containers} running. Nothing lasts. Enjoy it, menace.",
            "{machines} up and quiet. Shocking, given what an idiot set them up.",
            "{containers} running fine. Pure dumb luck, you lucky bastard.",
            "{machines} up. {quiet} is doing fuck all, just like its owner.",
            "{machines} up. Everything works, which is how horror films start, dipshit.",
            "{containers} running for an audience of one. A sad, sad audience.",
            "{machines} up. Your lab has better uptime than your social life.",
            "{containers} running to dodge a 10-euro subscription. Big brain move, arsehole.",
            "{machines} up, nothing on fire. Entropy is just pacing itself.",
            "{machines} up. The only thing here you didn't misconfigure is the silence.",
            "{machines} up. The electricity company sends its warmest regards, sucker.",
            "{containers} up, all that effort for a media server, you magnificent clown.",
        ]
        }
    }
}
