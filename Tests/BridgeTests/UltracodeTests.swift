import Testing

@testable import claude_bridge

@Suite("Ultracode keyword")
struct UltracodeTests {
    @Test("The word opts a turn in, wherever and however cased")
    func keywordMatches() {
        #expect(SessionStore.invokesUltracode("ultracode: audit this repo"))
        #expect(SessionStore.invokesUltracode("Fix the bug. ULTRACODE."))
        #expect(SessionStore.invokesUltracode("please Ultracode this"))
    }

    @Test("Substrings and plain prompts do not")
    func keywordRejects() {
        #expect(!SessionStore.invokesUltracode("the ultracoder wrote this"))
        #expect(!SessionStore.invokesUltracode("run the multiagent sweep"))
        #expect(!SessionStore.invokesUltracode(""))
    }

    @Test("The transcript's xhigh confirms ultracode rather than erasing it")
    func transcriptCannotDemoteUltracode() {
        #expect(SessionStore.reconciledEffort(stored: "ultracode", observed: "xhigh") == "ultracode")
        #expect(SessionStore.reconciledEffort(stored: "ultracode", observed: nil) == "ultracode")
        #expect(SessionStore.reconciledEffort(stored: "ultracode", observed: "") == "ultracode")
    }

    @Test("An effort actually changed elsewhere still wins")
    func terminalPickWins() {
        #expect(SessionStore.reconciledEffort(stored: "ultracode", observed: "high") == "high")
        #expect(SessionStore.reconciledEffort(stored: "ultracode", observed: "max") == "max")
        #expect(SessionStore.reconciledEffort(stored: "medium", observed: "xhigh") == "xhigh")
        #expect(SessionStore.reconciledEffort(stored: "medium", observed: nil) == "medium")
    }
}
