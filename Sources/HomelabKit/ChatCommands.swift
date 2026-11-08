import Foundation

/// The chat's slash commands as the "/" menu and the suggestions under a typed "/" show them: the commands the server
/// lists in `/info`, each with one line saying what it does. The line comes from the server when it sends one
/// (`ServerInfo.commandHelp`), else from a small built-in list for the commands of the agent and the reference
/// server, else there is none (the command shows as it is).
public enum ChatCommands {
    public struct Command: Sendable, Equatable, Identifiable {
        /// "/pending"
        public var name: String
        /// One line, or nil when nobody says what it does.
        public var help: String?
        /// It needs something after it ("/last <job>"): picking it puts it in the field instead of sending it.
        public var takesArgument: Bool

        public var id: String { name }

        public init(name: String, help: String? = nil, takesArgument: Bool = false) {
            self.name = name; self.help = help; self.takesArgument = takesArgument
        }
    }

    /// What the known commands do. Only used for a command the server lists itself; never offered on its own.
    static let known: [String: (help: String, takesArgument: Bool)] = [
        "/help": ("Lists every command", false),
        "/pending": ("Actions waiting for your answer", false),
        "/last": ("The latest report of a job", true),
        "/memory": ("What the agent remembers", false),
        "/forget": ("Deletes a note from /memory", true),
        "/usage": ("Runs and tokens, today and this week", false),
        "/autonomy": ("What may run by itself, and recent automatic runs", false),
        "/jobs": ("The jobs and when they run", false),
        "/run": ("Runs a job now", true),
        "/ask": ("Asks a job a question with fresh data", true),
        "/opus": ("Answers with the stronger model", true),
        "/pause": ("Stops all automatic actions", false),
        "/resume": ("Allows automatic actions again", false),
        "/never": ("Takes a standing approval back", true),
        "/sick": ("No wake-up and no train alert", false),
        "/off": ("A free day the timetable doesn't know", true),
        "/back": ("Undoes /sick and /off", false),
    ]

    /// The server's commands with their lines, in the server's order.
    public static func list(_ info: ServerInfo?) -> [Command] {
        guard let info else { return [] }
        return info.commands.map { name in
            let k = known[name.lowercased()]
            let own = info.commandHelp[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Command(name: name, help: own.flatMap { $0.isEmpty ? nil : $0 } ?? k?.help,
                           takesArgument: k?.takesArgument ?? false)
        }
    }

    /// The commands that fit what is typed: only while the field holds a "/" and the start of one word. "/" alone
    /// lists them all; "/pe" the ones starting with it; a finished command ("/pending") or a space after it, none.
    public static func suggestions(for draft: String, in commands: [Command]) -> [Command] {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("/"), !t.contains(where: \.isWhitespace) else { return [] }
        let typed = t.lowercased()
        return commands.filter { $0.name.lowercased().hasPrefix(typed) && $0.name.lowercased() != typed }
    }

    /// What picking a command does: send it now, or put it in the field ("/last ") to finish there.
    public enum Pick: Sendable, Equatable {
        case send(String)
        case fill(String)
    }

    public static func pick(_ command: Command) -> Pick {
        command.takesArgument ? .fill(command.name + " ") : .send(command.name)
    }
}
