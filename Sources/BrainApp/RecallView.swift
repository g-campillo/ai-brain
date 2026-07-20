import BrainKit
import SwiftUI

/// Read-only log of real UserPromptSubmit recall decisions — what the gate saw
/// and what it injected, per session prompt. PlaygroundView answers "what would
/// happen?"; this answers "what actually happened?".
struct RecallView: View {
    @Environment(BrainStore.self) private var store

    var body: some View {
        if store.recallEvents.isEmpty {
            ContentUnavailableView(
                "No recall decisions logged yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Every prompt that runs the brain's recall hook lands here, injected or not.")
            )
        } else {
            List(store.recallEvents) { event in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(event.createdAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        if let cwd = event.cwd {
                            Text((cwd as NSString).lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        let injected = event.hits.filter(\.injected).count
                        if injected > 0 {
                            Text("INJECTED \(injected)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.green.opacity(0.2), in: Capsule())
                        } else {
                            Text("NO INJECT")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.gray.opacity(0.2), in: Capsule())
                        }
                        Spacer()
                        Text("corpus n=\(event.vectorCount) · sim \(fmt(event.vectorMean)) ± \(fmt(event.vectorStd))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(event.prompt)
                        .font(.callout)
                        .lineLimit(2)
                    ForEach(Array(event.hits.enumerated()), id: \.offset) { _, hit in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(hit.injected ? .green : hit.confident ? .yellow : .gray.opacity(0.4))
                                .frame(width: 6, height: 6)
                            Text("[\(hit.noteId)] \(hit.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if hit.matchedAllKeywords {
                                Text("KW").font(.caption2.bold()).foregroundStyle(.blue)
                            }
                            Text(scoreLine(hit, event: event))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func scoreLine(_ hit: RecallEvent.Hit, event: RecallEvent) -> String {
        var parts = ["rrf \(String(format: "%.4f", hit.rrf))"]
        if let sim = hit.sim {
            parts.append("sim \(fmt(sim))")
            if event.vectorStd > 1e-4 {
                parts.append("z \(String(format: "%.2f", (sim - event.vectorMean) / event.vectorStd))")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func fmt(_ value: Float) -> String { String(format: "%.3f", value) }
}
