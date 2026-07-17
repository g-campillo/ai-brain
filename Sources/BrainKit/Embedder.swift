import Foundation
import NaturalLanguage

public enum BrainError: Error {
    case embeddingModelUnavailable
    case emptyEmbedding
}

/// Text → L2-normalized sentence vector via Apple's on-device NLContextualEmbedding.
public final class Embedder {
    private let model: NLContextualEmbedding
    public let dimension: Int

    /// Loads the English contextual embedding model, downloading its assets on first use.
    public static func ready() async throws -> Embedder {
        guard let model = NLContextualEmbedding(language: .english) else {
            throw BrainError.embeddingModelUnavailable
        }
        if !model.hasAvailableAssets {
            _ = try await model.requestAssets()
        }
        try model.load()
        return Embedder(model: model)
    }

    private init(model: NLContextualEmbedding) {
        self.model = model
        self.dimension = model.dimension
    }

    /// Mean-pools token vectors, then L2-normalizes so cosine reduces to a dot product downstream.
    public func embed(_ text: String) throws -> [Float] {
        let result = try model.embeddingResult(for: text, language: .english)
        var sum = [Double](repeating: 0, count: dimension)
        var tokens = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
            tokens += 1
            return true
        }
        guard tokens > 0 else { throw BrainError.emptyEmbedding }
        var mean = sum.map { Float($0 / Double(tokens)) }
        let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { for i in mean.indices { mean[i] /= norm } }
        return mean
    }
}
