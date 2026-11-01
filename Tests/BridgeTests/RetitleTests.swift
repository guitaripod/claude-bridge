import Testing

@testable import claude_bridge

@Suite("A conversation's title follows its topic")
struct RetitleTests {
    @Test("A title is looked at again once a few messages have gone by")
    func dueAfterThreeMessages() {
        #expect(!SessionStore.retitleDue(turn: 1, titledAt: 1))
        #expect(!SessionStore.retitleDue(turn: 3, titledAt: 1))
        #expect(SessionStore.retitleDue(turn: 4, titledAt: 1))
        #expect(SessionStore.retitleDue(turn: 3, titledAt: nil))
    }

    @Test("KEEP, silence and a restatement leave the title alone")
    func keepsTheTitle() {
        #expect(Titler.replacement(from: "KEEP", current: "Fix login crash") == nil)
        #expect(Titler.replacement(from: " keep.\n", current: "Fix login crash") == nil)
        #expect(Titler.replacement(from: "", current: "Fix login crash") == nil)
        #expect(Titler.replacement(from: "\"Fix login crash\"", current: "Fix login crash") == nil)
        #expect(Titler.replacement(from: "One\nTwo", current: "Fix login crash") == nil)
    }

    @Test("A moved topic wears the new title")
    func takesTheNewTitle() {
        #expect(
            Titler.replacement(from: "\"Migrate settings to SQLite.\"", current: "Fix login crash")
                == "Migrate settings to SQLite")
    }
}
