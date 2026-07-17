import Testing
@testable import BrainKit

@Suite struct EmbedderTests {
    @Test func embedsRelatedTextCloserThanUnrelated() async throws {
        let embedder = try await Embedder.ready()

        let a = try embedder.embed("deploy hangs on publish")
        let b = try embedder.embed("publishing times out during deployment")
        let c = try embedder.embed("my favorite pasta recipe uses basil and garlic")

        #expect(a.count == embedder.dimension)
        #expect(!a.isEmpty)

        #expect(cosine(a, b) > cosine(a, c))
    }
}

private func cosine(_ x: [Float], _ y: [Float]) -> Float {
    let dot = zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
    let nx = (x.reduce(0) { $0 + $1 * $1 }).squareRoot()
    let ny = (y.reduce(0) { $0 + $1 * $1 }).squareRoot()
    return dot / (nx * ny)
}
