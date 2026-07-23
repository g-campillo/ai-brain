import SwiftUI

/// SwiftUI `Text` ignores `PresentationIntent`, so a full-markdown parse renders
/// flattened. Split the parsed string into blocks by intent identity and lay
/// them out. Re-parsing per streamed delta is fine at answer size (a few KB).
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        let blocks = Self.blocks(from: markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { i in // append-only stream → index ids stable
                view(for: blocks[i])
            }
        }
    }

    struct Block {
        enum Kind: Equatable {
            case paragraph, code, quote, divider
            case header(Int)
            case listItem(prefix: String) // "•" or "3."
        }
        var kind: Kind
        var text: AttributedString
    }

    // ponytail: tables render as plain paragraphs, nested lists lose indentation,
    // code-in-list-item renders top-level — upgrade if brain answers ever hit them
    static func blocks(from markdown: String) -> [Block] {
        guard let attr = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            return [Block(kind: .paragraph, text: AttributedString(markdown))] // never crash mid-stream
        }
        var blocks: [Block] = []
        var currentID = Int.min
        var lastIntent: PresentationIntent?
        for run in attr.runs {
            let intent = run.presentationIntent
            let (kind, id) = classify(intent)
            var slice = AttributedString(attr[run.range])
            slice.presentationIntent = nil // Text must not see block intents
            if id == currentID, !blocks.isEmpty {
                // Same block: inline-styling runs, or a later paragraph in the same
                // list item — the parser strips separators, so re-add one.
                if intent != lastIntent { blocks[blocks.count - 1].text += AttributedString("\n") }
                blocks[blocks.count - 1].text += slice
            } else {
                blocks.append(Block(kind: kind, text: slice))
                currentID = id
            }
            lastIntent = intent
        }
        return blocks
    }

    /// Reduce an intent stack (paragraph-in-listItem-in-list, …) to one renderable
    /// kind plus the identity used to group adjacent runs. Scans every component so
    /// it works whichever end of `components` is innermost.
    private static func classify(_ intent: PresentationIntent?) -> (Block.Kind, Int) {
        guard let intent else { return (.paragraph, -1) }
        var ordered = false
        var listItem: (id: Int, ordinal: Int)?
        var quote: Int?
        for c in intent.components {
            switch c.kind {
            case .codeBlock: return (.code, c.identity)
            case .header(let level): return (.header(level), c.identity)
            case .thematicBreak: return (.divider, c.identity)
            case .listItem(let ordinal): listItem = (c.identity, ordinal)
            case .orderedList: ordered = true
            case .blockQuote: quote = c.identity
            default: break // paragraph, unorderedList, tables → fall through
            }
        }
        if let listItem { return (.listItem(prefix: ordered ? "\(listItem.ordinal)." : "•"), listItem.id) }
        if let quote { return (.quote, quote) }
        return (.paragraph, intent.components.first?.identity ?? -1)
    }

    // Rendering: fills + vibrancy only — no glass in here.
    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.text).lineSpacing(3)
        case .header(let level):
            Text(block.text)
                .font(level <= 1 ? Font.title3.weight(.semibold)
                    : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case .code:
            // ponytail: wraps long lines instead of h-scrolling — revisit if code answers get wide
            Text(String(block.text.characters).trimmingCharacters(in: .newlines))
                .font(.callout.monospaced())
                .lineSpacing(2)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .listItem(let prefix):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(prefix).foregroundStyle(.secondary).monospacedDigit()
                Text(block.text).lineSpacing(3)
            }
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                Text(block.text).foregroundStyle(.secondary).lineSpacing(3)
            }
        case .divider:
            Divider()
        }
    }
}
