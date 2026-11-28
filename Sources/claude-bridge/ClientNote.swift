/// What Claude is told about where its replies are read, appended to Claude Code's own system
/// prompt rather than replacing it, so the CLI keeps its tool guidance, its safety rules and its
/// identity. Only facts about the screen, never a style of its own, so it does not argue with the
/// person's own CLAUDE.md.
///
/// The text never varies: it sits in the cached prefix of every request. Claude Code records a
/// conversation's system prompt on its first request and keeps that record through every resume
/// until the conversation is compacted, so a chat begun here and resumed later in a terminal still
/// carries it, which is why it says the person may be away rather than that they are, and a chat
/// begun in a terminal gains it only at its next compaction. `BRIDGE_CLIENT_NOTE=0` leaves it off.
enum ClientNote {
    /// For an app that shows a picture, a video or a song whose path a reply names
    /// (`X-Client-Features: media-by-path`).
    static let mediaText = """
        This session is driven from Tailscode, an app on the user's phone, tablet or computer. \
        They may not be at this machine, so do not count on them seeing its terminal, windows or \
        browser. Your replies render as Markdown in a chat view: fenced code gets a copy button, \
        links are tappable and wide tables scroll sideways. Markdown images, raw HTML, Mermaid \
        and LaTeX do not render, and file paths are not tappable. To show the user a picture, a \
        video or an audio file on this machine, write its absolute path in your reply; Tailscode \
        shows it in the chat. Notifications and the chat list show only the first sentence or \
        two of your reply, so lead with the outcome.
        """

    static let text = """
        This session is driven from Tailscode, an app on the user's phone, tablet or computer. \
        They may not be at this machine, so do not count on them seeing its terminal, windows or \
        browser. Your replies render as Markdown in a chat view: fenced code gets a copy button, \
        links are tappable and wide tables scroll sideways. Markdown images, raw HTML, Mermaid \
        and LaTeX do not render, and file paths are not tappable. To show the user an image, \
        open it with your Read tool and name its file in your reply; an image you read without \
        naming it stays out of view. A video or audio file on this machine shows as a player \
        when your reply names its absolute path. Notifications and the chat list show only the first \
        sentence or two of your reply, so lead with the outcome.
        """

    /// For an agent other than Claude Code, read in an app that shows no file by its path: the
    /// facts about the screen alone, since the advice about pictures names a tool only Claude
    /// Code has.
    static let agentText = """
        This session is driven from Tailscode, an app on the user's phone, tablet or computer. \
        They may not be at this machine, so do not count on them seeing its terminal, windows or \
        browser. Your replies render as Markdown in a chat view: fenced code gets a copy button, \
        links are tappable and wide tables scroll sideways. Markdown images, raw HTML, Mermaid \
        and LaTeX do not render, and file paths are not tappable. Notifications and the chat list \
        show only the first sentence or two of your reply, so lead with the outcome.
        """

    /// What an agent that takes text at the end of its system prompt is handed as a conversation
    /// begins: the same facts Claude Code is given, in the form the app that began it can show.
    static func forAgent(enabled: Bool, mediaByPath: Bool) -> String? {
        guard enabled else { return nil }
        return mediaByPath ? mediaText : agentText
    }

    /// The one `--append-system-prompt` a launch carries: the note, then an expert's brief when the
    /// conversation is a task of one. The CLI keeps one appended prompt, so both ride in it.
    static func arguments(enabled: Bool, appendix: String? = nil, mediaByPath: Bool = false) -> [String] {
        let note = mediaByPath ? mediaText : text
        let parts = [enabled ? note : nil, appendix?.isEmpty == false ? appendix : nil].compactMap { $0 }
        return parts.isEmpty ? [] : ["--append-system-prompt", parts.joined(separator: "\n\n")]
    }
}
