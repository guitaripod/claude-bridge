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
}
