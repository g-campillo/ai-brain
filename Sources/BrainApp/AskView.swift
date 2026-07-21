import SwiftUI

struct AskView: View {
    let session: AskSession
    @AppStorage("askModel") private var model = "sonnet"
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
                TextField("Ask your brain…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit(submit)
                if session.isStreaming {
                    ProgressView().controlSize(.small)
                }
                Picker("Model", selection: $model) {
                    Text("Fable 5").tag("fable")
                    Text("Opus 4.8").tag("opus")
                    Text("Sonnet 5").tag("sonnet")
                    Text("Haiku 4.5").tag("haiku")
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(16)

            if !session.turns.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(session.turns) { turn in
                            switch turn.role {
                            case .user:
                                Text(turn.text)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            case .assistant:
                                if !turn.text.isEmpty {
                                    Text(rendered(turn.text))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        if let status = session.status {
                            Label(status, systemImage: "magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let error = session.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                Text("esc to close · ⌥space")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            // Fresh hosting view per summon; the async hop makes focus stick.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: session.turns.isEmpty) { _, empty in
            AskPanelController.shared.setExpanded(!empty)
        }
    }

    private func submit() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        input = "" // field stays focused for follow-ups
        session.ask(question, model: model)
    }

    private func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}
