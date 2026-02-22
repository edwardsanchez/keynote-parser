//
//  OutlinerModels.swift
//  Keynote Outliner
//

import Foundation

struct DeckFileFingerprint: Codable, Equatable, Sendable {
    var url: String
    var sha256: String
    var mtime: Double
    var size: Int
}

struct SlideRowModel: Identifiable, Equatable, Sendable {
    var index: Int
    var keynoteIndex: Int?
    var slideNodeId: String
    var slideId: String
    var noteArchiveId: String?
    var noteStorageId: String?
    var baseNoteText: String
    var editedNoteText: String
    var isSkipped: Bool
    var isEditable: Bool
    var loadIssue: String?
    var thumbnailPath: String?

    var id: String { slideId }
    var isDirty: Bool { baseNoteText != editedNoteText }
}

struct DeckSnapshot: Equatable, Sendable {
    var file: DeckFileFingerprint
    var slides: [SlideRowModel]
}

enum SaveMode: String, Codable, Sendable {
    case strict
    case merge
    case overwrite
}

enum ConflictAction: Sendable {
    case tryMerge
    case refresh
    case overwrite
    case cancel
}

struct SaveRowState: Codable, Sendable {
    var slideId: String
    var baseText: String
    var editedText: String
}

struct SaveStatePayload: Codable, Sendable {
    var baseFile: DeckFileFingerprint
    var rows: [SaveRowState]
}

struct SaveConflict: Codable, Equatable, Identifiable, Sendable {
    var slideId: String
    var index: Int
    var reason: String
    var baseText: String?
    var localText: String?
    var remoteText: String?

    var id: String {
        "\(slideId)-\(index)-\(reason)"
    }
}

enum BackendSaveStatus: String, Codable, Sendable {
    case saved
    case conflict
    case error
}

struct SaveResponse: Codable, Sendable {
    var status: BackendSaveStatus
    var file: DeckFileFingerprint?
    var message: String?
    var conflicts: [SaveConflict]?
    var savedRows: Int?
    var error: String?
}
