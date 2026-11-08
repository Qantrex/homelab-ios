import Foundation

/// The lines. Rules (VoiceTests): a full sentence, within the place's `maxLength` once filled, distinct per
/// personality, no markdown characters (some go through `LocalizedStringKey`), no "Ah," / "Let's" / dashes. "Done."
/// starts every line after an action that worked. Each reads as one quick remark, with no setup that lacks a
/// punchline and no sentence pattern repeated from line to line. Dry is deadpan with the odd dig at officialdom;
/// Snarky teases the owner and the hardware, with a little everyday politics; Ultrakill is another tier: harsh,
/// profane, merciless about the owner and the lab, satire of politics in general terms (never slurs, protected
/// groups, anything sexual, self-harm, real people or threats).
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
            ["Nothing needs you.", "The machines are behaving.", "No news, which is the good kind.",
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
            ["Nothing to report.", "All in order. Unusually so.",
             "Nothing amiss, much like a well-run ministry, in theory."]
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
            ["Busy. More than its fair share, as usual.", "Working hard. More than it was paid for."]
        case .reasonPower:
            ["Cheap power supplies are rarely a saving.", "Short of power, like everyone these days."]
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
             "Done. Fewer forms than the city would need."]
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
             "Even the cheap hardware behaves.", "Stop refreshing. It's fine.",
             "Stable. Unlike rent or the coalition."]
        case .todayHeadsUp:
            ["Something is sulking.", "Not broken. Just needy.", "A warning. Ignore it at your peril.",
             "One of your boxes wants attention.", "Mild decay. Infrastructure, but yours."]
        case .todayAlarm:
            ["Of course it broke now.", "It worked yesterday. Allegedly.", "Coffee first. Then this.",
             "Cheaper than the cloud, they said.", "Something died. Go find the body."]
        case .todayUnknown:
            ["The lab is giving you the silent treatment.", "VPN off again?", "Did someone trip over a cable?",
             "No signal. The railway calls this a delay."]

        case .labAllGood:
            ["All good. Don't touch anything.", "Nothing broken. Must be a public holiday.",
             "All good. Screenshot it for posterity.", "Stable. More than any campaign promise managed."]
        case .labWarnings:
            ["{count}. Your lab is passive-aggressive today.", "Ignoring warnings is a strategy. Technically.",
             "{count}. They won't read themselves.", "{count}. Enough for a week-long culture war."]
        case .labProblems:
            ["{count}. Off and on again is still an option.", "Broken. Shocking, said nobody.",
             "Problems. The weekend just got planned.", "{count}. No bailout coming. You're not a bank."]
        case .labUnknown:
            ["No idea. The server's being mysterious.", "Unknown. Like the rent next year.",
             "Unknown. Checked the cable? Really checked?", "Status unknown. Like the ministry's plan for anything."]

        case .reasonDown:
            ["Offline. Have you tried actually looking at it?",
             "Gone. Back when it feels like it, like the bus.",
             "Unreachable, like property management in winter."]
        case .reasonContainer:
            ["Works on the maintainer's machine. Not on yours.", "It crashed. Read the logs, they won't bite.",
             "Restart it. Bailouts work for banks, why not here?"]
        case .reasonDisk:
            ["You don't need all of that. You know you don't.", "Delete something. Anything. Please.",
             "Full, like the city's housing waitlist."]
        case .reasonHot:
            ["Toasty. Maybe not next to the heater?", "Hot enough to heat the flat. Cheaper than gas.",
             "Free heating. The energy ministry calls that policy."]
        case .reasonLoad:
            ["Working harder than you, apparently.", "It's not slow. It's overcommitted. Like you.",
             "Slow. Still faster than a city construction site."]
        case .reasonPower:
            ["That USB charger was never a power supply.", "Underfed, like the public budget.",
             "Rationed power. The energy crisis never ended."]
        case .reasonBackup:
            ["No backup. Bold move.", "Your data is one bad day from gone. Fun.",
             "No backup. Like the pension system."]
        case .reasonOther:
            ["This is why the cloud costs money.", "Self-hosting: free as in free time.",
             "Fixable. By you. Today, ideally.", "Officially a 'temporary disruption'. Ask the railway."]

        case .emptyApprovals:
            ["Nothing to approve. The agent is behaving.", "Nothing to approve. The robot is napping.",
             "Nothing to approve. Parliament calls that a good week."]
        case .emptyTodos:
            ["No to-dos. Who are you and what have you done?", "Empty. You'll find something to put off.",
             "Nothing to do. Ideal for a supervisory board."]
        case .emptyDeadlines:
            ["No deadlines. Enjoy it, it never lasts.", "Nothing due. Someone planned ahead. Not you.",
             "No deadlines. As binding as a climate target."]
        case .emptyParcels:
            ["No parcels. Your bank account sends its thanks.", "Nothing coming. Did online shopping finally break?",
             "No parcels. The postman gets a day off."]
        case .emptySearch:
            ["Nothing found. Typo, or very niche taste?", "Nothing. Even streaming services gave up on that one.",
             "Nothing found. Probably region-locked."]
        case .emptyChat:
            ["Say something. It's lonely in here.", "It knows your lab better than you do.",
             "Go on, ask. It won't judge. Much."]

        case .emptyDeals:
            ["No deals. Everyone prices like it is 2021.", "Nothing cheap. Your wallet is safe, your hobby less so.",
             "Nothing worth buying. A rare moment of peace."]

        case .done:
            ["Done. You're basically a sysadmin now.", "Done. Try not to break it again.",
             "Done. That was the easy part.", "Done. Quicker than a government IT project.",
             "Done. No form, no stamp. Revolutionary."]
        case .failed:
            ["Nope. Have you tried reading the error?", "Failed. The server has opinions.",
             "Failed. Call it a pilot project and ask for funding."]

        case .noticeProblem:
            ["Something broke. Of course it did.", "Fresh problem, still warm.", "New corpse. Bring a terminal."]
        case .noticeWarning:
            ["A warning. You'll ignore it, won't you?", "Something wants attention. Again.",
             "Something's wobbling. So is the coalition."]
        case .noticeRecovered:
            ["It's back. Pretend you fixed it.", "Fixed itself. Take the credit anyway.",
             "Back up. Nobody will thank you for that."]
        case .noticeWaiting:
            ["It won't approve itself.", "The agent has ideas again.", "A robot awaits your blessing.",
             "Sign here. In triplicate, for tradition."]

        case .noticeDeal:
            ["Cheap thing found. Try not to hoard.", "A bargain. Your wallet will not survive.",
             "Underpriced. Someone forgot to be greedy."]
        }
    }

    // MARK: Ultrakill

    static func ultrakill(_ place: Voice.Place) -> [String] {
        switch place {
        case .todayCalm:
            ["All quiet. Disappointing, honestly.", "It works. Don't touch it, you menace.",
             "Calm, like a morgue. Enjoy, loser.", "Everything's up. Pure luck, not skill.",
             "Stable. Your life isn't, you mess.", "Nothing broke. Even entropy finds you boring."]
        case .todayHeadsUp:
            ["Something's dying. Slowly. Like your hobby.", "A warning. Ignore it like everything else.",
             "Not dead yet. Give it a weekend, dumbass.", "Your lab is sulking. Draft the eulogy.",
             "A warning. Fix it, you lazy shit."]
        case .todayAlarm:
            ["Shit's broken. Go fix it, genius.", "Time of death: just now. Cause: you, idiot.",
             "Fucked. Properly. Coffee, then crying.", "It broke. Great hobby. Really fucking great.",
             "Another casualty of your shit homelab."]
        case .todayUnknown:
            ["The lab's ignoring you. Smart lab.", "No signal. Dead, or unionising.",
             "Lost contact. Even Chat Control can't find it.", "Silence. Like the city office on a Friday.",
             "No answer. Not even your damn lab likes you."]

        case .labAllGood:
            ["No problems. Rarer than an affordable flat in a big city.", "All good. A fucking miracle, given who runs it.",
             "All quiet. Entropy is only on a coffee break.", "All good. A consultant somewhere bills for that."]
        case .labWarnings:
            ["{count}. Transitory, like inflation was supposed to be.", "{count}. The EU is drafting a regulation.",
             "{count}. Fix them, you lazy bastard.", "{count}. Slow decay, like a pension reform.", "Warnings. Ignore them like the climate ones."]
        case .labProblems:
            ["{count}. Form a commission. Report due in 2031.", "{count}. Fucked. Blame the previous government.", "Problems. Obviously. It's your lab, you muppet.",
             "{count}. Absolutely fucked. Like your weekend.", "Burning. The climate summit arrives by jet."]
        case .labUnknown:
            ["Unknown. Even mass surveillance can't find it.", "No idea. Neither does the central bank.",
             "Dark. Maybe dead. Go check, you coward prick.", "No signal. The VPN or your cable management."]

        case .reasonDown:
            ["Gone, unlike every 'temporary' tax.", "Dead. Saving energy, as the ministry suggested.",
             "{host} is gone. Plug it in properly this time, moron.", "{host} died. It had a nicer life than you."]
        case .reasonContainer:
            ["Microservices: outsourcing your own failures.", "Restart it. Pray to the YAML gods, heathen.",
             "Dead on arrival, like every shit AI startup.", "Docker was a damn mistake. This is the receipt."]
        case .reasonDisk:
            ["Full to the brim with garbage. Like parliament.", "No space left. Delete your pirated crap, hoarder.",
             "Charge the files rent. It works for property funds.", "Storage inflation. Transitory, experts promise."]
        case .reasonHot:
            ["Fucking cupboard. You built an oven.", "Global warming, local edition. No summit will save it.",
             "Hot as the runway of a climate summit."]
        case .reasonLoad:
            ["Overworked and underpaid. Like everyone, really.", "Doing three jobs. Welcome to the gig economy.",
             "Burning cycles for nothing, like every AI demo. Shit.", "Working harder than you ever did, loser."]
        case .reasonPower:
            ["Underpowered. Energy policy, in miniature.", "Not enough current. The grid calls that 'stable'.",
             "Cheap PSU. Cheap owner. Cheap shit, consistent."]
        case .reasonBackup:
            ["No backup. The pension system sends solidarity.", "Your data's gone. The cloud would've sold it first.",
             "Failed. Even data retention keeps better copies.", "No backup. Enjoy losing everything, genius."]
        case .reasonOther:
            ["Broken. Someone will hold a damn press conference.", "Not my department. Try the city office, form B-17.",
             "The market will fix it. It won't.", "Fix it, dumbass. Nobody else is coming."]

        case .emptyApprovals:
            ["Nothing to approve. The bot gave up on your lazy ass.", "Nothing to approve. The AI follows the AI Act. Probably.",
             "Nothing to approve. Go touch grass, nerd."]
        case .emptyTodos:
            ["No to-dos. Enjoy it before the next reform adds some.", "Nothing to do. Perfect for a board seat.",
             "Empty. Even your procrastination ran out of material."]
        case .emptyDeadlines:
            ["Nothing due. The tax office is just reloading.", "Nothing due. Postponed indefinitely, like school reform.",
             "Nothing due. The peak of your career, honestly, arse."]
        case .emptyParcels:
            ["No parcels. Your bank account can breathe.", "Nothing coming. Supply chain or self-control? Unclear.",
             "No parcels. The tech oligopoly misses your money."]
        case .emptySearch:
            ["Nothing found. The algorithm decided you don't need it.", "No results. Even the surveillance state found more.",
             "Nothing found. Not even a cookie banner.", "Nothing. Learn to spell, you absolute prick."]
        case .emptyChat:
            ["Say something. We're all dying anyway.", "Type something. The void is listening.",
             "Ask. It's cheaper than a consultant.", "Talk to it. Nobody else will, loser.",
             "It's the only AI here not raising money."]

        case .emptyDeals:
            ["No deals. Inflation got there first.", "Nothing underpriced. The invisible hand is on lunch.",
             "No bargains. Late capitalism sends its regards."]

        case .done:
            ["Done. Faster than any ministry has ever managed.", "Done. No city office, no stamp. Revolutionary.",
             "Done. More delivery than the last election promised.", "Done. Put it on LinkedIn, you pretentious prick.",
             "Done. Even a broken clock, you absolute fluke."]
        case .failed:
            ["Didn't work. File a complaint. Nobody reads them.", "Failed. The pilot project is over, and so is your weekend.",
             "Failed. Blame the EU. Everyone else does.", "Failed. Spectacularly. Fucking good show, genius."]

        case .noticeProblem:
            ["Something broke. Rent went up anyway.", "New corpse. Bring a shovel and a terminal.",
             "Breaking news, literally. Get up, bastard.", "It's fucked. Details inside, if you dare."]
        case .noticeWarning:
            ["Early warning. Ignore it like the climate ones.", "A warning. Outrage cycle starts in 3, 2, 1.",
             "Warning. You'll ignore it, you damn fool."]
        case .noticeRecovered:
            ["It recovered. Unlike housing affordability.", "Resurrected. No miracle, just a restart.",
             "Fixed itself. You were useless, as usual, shit."]
        case .noticeWaiting:
            ["Decide. Faster than the city office, ideally.", "The bot did the work. Press the button.",
             "Approve it before entropy does.", "The bot asks first. Unlike the data brokers.",
             "Click yes, you indecisive wreck."]

        case .noticeDeal:
            ["A bargain. The market blinked first.", "Underpriced. Someone's loss, your clutter.",
             "Cheap hardware. Buy it, you hoarding goblin."]
        }
    }
}
