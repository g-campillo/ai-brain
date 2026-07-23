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
                    .foregroundStyle(.tint)
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
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            if !session.turns.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(session.turns) { turn in
                            switch turn.role {
                            case .user:
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .foregroundStyle(.tint)
                                        .imageScale(.small)
                                    Text(turn.text)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, turn.id == session.turns.first?.id ? 0 : 14) // between-exchange gap
                            case .assistant:
                                if !turn.text.isEmpty {
                                    MarkdownText(markdown: turn.text)
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
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .defaultScrollAnchor(.top, for: .alignment) // underfull content reads from the top
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges) // overflow: stick to the streaming tail
                Text("esc to close · ⌥space")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
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
}
