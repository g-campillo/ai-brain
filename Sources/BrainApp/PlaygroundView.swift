import BrainKit
import SwiftUI

/// Runs the exact retrieval pipeline the hooks use, exposing scores — the tool
/// for answering "why did/didn't the brain inject that note?".
struct PlaygroundView: View {
    @Environment(BrainStore.self) private var store
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Simulate a prompt…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { run() }
                Button("Search") { run() }
                    .disabled(query.isEmpty || running)
            }
            .padding()

            if let result {
                let confident = result.highConfidenceHits()
                let confidentIDs = Set(confident.compactMap(\.note.id))
                List {
                    Section {
                        ForEach(Array(result.hits.enumerated()), id: \.element.note.id) { rank, hit in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("#\(rank + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(hit.note.title).font(.headline)
                                        if confidentIDs.contains(hit.note.id ?? -1) {
                                            Text("WOULD INJECT")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(.green.opacity(0.2), in: Capsule())
                                        }
                                        if hit.matchedAllKeywords {
                                            Text("KW").font(.caption2.bold()).foregroundStyle(.blue)
                                        }
                                    }
                                    Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                    Text(scoreLine(hit, result: result))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    } header: {
                        Text("corpus n=\(result.vectorCount) · sim mean \(fmt(result.vectorMean)) ± \(fmt(result.vectorStd)) · gate: z ≥ 1.5 or full keyword match")
                    }
                }
            } else {
                ContentUnavailableView(
                    "Type a prompt to see what Claude would be shown",
                    systemImage: "scope",
                    description: Text("Runs hybrid search + the hook confidence gate against the live database.")
                )
            }
        }
        .onChange(of: query) { result = nil }
    }

    private func run() {
        running = true
        Task {
            result = await store.playgroundSearch(query)
            running = false
        }
    }

    private func scoreLine(_ hit: SearchHit, result: SearchResult) -> String {
        var parts = ["rrf \(String(format: "%.4f", hit.score))"]
        if let sim = hit.vectorSimilarity {
            parts.append("sim \(fmt(sim))")
            if result.vectorStd > 1e-4 {
                parts.append("z \(String(format: "%.2f", (sim - result.vectorMean) / result.vectorStd))")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func fmt(_ value: Float) -> String { String(format: "%.3f", value) }
}
