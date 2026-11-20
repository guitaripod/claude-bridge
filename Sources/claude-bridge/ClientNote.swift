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
    static let text = """
        This session is driven from Tailscode, an app on the user's phone, tablet or computer. \
        They may not be at this machine, so do not count on them seeing its terminal, windows or \
        browser. Your replies render as Markdown in a chat view: fenced code gets a copy button, \
        links are tappable and wide tables scroll sideways. Markdown images, raw HTML, Mermaid \
        and LaTeX do not render, and file paths are not tappable. To show the user an image, \
        open it with your Read tool and name its file in your reply; an image you read without \
        naming it stays out of view. Notifications and the chat list show only the first \
        sentence or two of your reply, so lead with the outcome.
        """

    static func arguments(enabled: Bool) -> [String] {
        enabled ? ["--append-system-prompt", text] : []
    }
}
