/// Splits a note into embedding-sized chunks: the whole note when short,
/// otherwise one title-prefixed chunk per markdown heading section.
public enum Chunker {
    public static func chunks(title: String, body: String, maxChars: Int = 1500) -> [String] {
        let full = title + "\n\n" + body
        if full.count <= maxChars { return [full] }

        var sections: [String] = []
        var current = ""
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#"), !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(current)
        }
        // ponytail: oversize sections are hard-truncated; split by paragraph if recall suffers.
        return sections.map { String((title + "\n\n" + $0).prefix(maxChars)) }
    }
}
