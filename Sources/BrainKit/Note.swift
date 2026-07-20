import Foundation
import GRDB

public enum NoteSource: String, Codable, Sendable {
    case manual, harvest
}

public enum NoteStatus: String, Codable, Sendable {
    case active, archived
}

public struct Note: Codable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note"

    public var id: Int64?
    public var type: NoteType
    public var title: String
    public var body: String
    public var project: String?
    public var site: String?
    public var tags: [String]
    public var jiraKey: String?
    public var source: NoteSource
    public var status: NoteStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        type: NoteType,
        title: String,
        body: String,
        project: String? = nil,
        site: String? = nil,
        tags: [String] = [],
        jiraKey: String? = nil,
        source: NoteSource = .manual,
        status: NoteStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.body = body
        self.project = project
        self.site = site
        self.tags = tags
        self.jiraKey = jiraKey
        self.source = source
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
