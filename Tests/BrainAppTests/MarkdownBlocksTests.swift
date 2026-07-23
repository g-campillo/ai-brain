import Foundation
import Testing
@testable import BrainApp

@Suite struct MarkdownBlocksTests {
    @Test func splitsBlockKindsInOrder() {
        let md = """
        Intro with **bold** and `inline code`.

        ## Heading

        - first bullet
        - second bullet

        1. ordered item

        ```swift
        let x = 1
        ```

        > quoted line
        """
        let blocks = MarkdownText.blocks(from: md)
        #expect(blocks.map(\.kind) == [
            .paragraph,
            .header(2),
            .listItem(prefix: "•"),
            .listItem(prefix: "•"),
            .listItem(prefix: "1."),
            .code,
            .quote,
        ])
        #expect(String(blocks[5].text.characters).contains("let x = 1"))
        // Inline styling survives inside a block: bold run present in the paragraph.
        #expect(blocks[0].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func unterminatedFenceMidStreamIsCode() {
        // Streaming: an open ``` fence is valid CommonMark (runs to end of input).
        let blocks = MarkdownText.blocks(from: "Setup:\n\n```swift\nlet partial =")
        #expect(blocks.map(\.kind) == [.paragraph, .code])
        #expect(String(blocks[1].text.characters).contains("let partial ="))
    }

    @Test func plainTextNeverEmpty() {
        #expect(!MarkdownText.blocks(from: "just words").isEmpty)
        #expect(MarkdownText.blocks(from: "").isEmpty || MarkdownText.blocks(from: "").allSatisfy { String($0.text.characters).isEmpty })
    }
}
