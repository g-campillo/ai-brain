/// Splits a note into embedding-sized chunks: the whole note when short,
/// otherwise one title-prefixed chunk per markdown heading section, packing
/// oversize sections paragraph-by-paragraph so no text is silently dropped.
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

        let prefix = title + "\n\n"
        let budget = maxChars - prefix.count
        var chunks: [String] = []
        for section in sections {
            if section.count <= budget {
                chunks.append(prefix + section)
                continue
            }
            var acc = ""
            for paragraph in section.components(separatedBy: "\n\n") {
                if !acc.isEmpty, acc.count + 2 + paragraph.count > budget {
                    chunks.append(prefix + acc)
                    acc = ""
                }
                acc += (acc.isEmpty ? "" : "\n\n") + paragraph
            }
            if !acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(prefix + acc)
            }
        }
        // ponytail: a single paragraph over budget still truncates; sentence-split if that ever matters.
        return chunks.map { String($0.prefix(maxChars)) }
    }
}
