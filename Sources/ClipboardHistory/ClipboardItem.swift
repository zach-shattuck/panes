import Foundation

nonisolated struct ClipboardItem: Sendable {
    enum Kind: String, Sendable {
        case text
        case image
        case fileList
    }

    let id: Int64
    let createdAt: Date
    let kind: Kind
    /// Text content, or newline-joined paths for file lists. Drives search.
    let text: String?
    /// PNG/TIFF bytes for images.
    let data: Data?
    let sourceBundleID: String?
    /// Pinned items sort to the top and are exempt from age/capacity pruning.
    let pinned: Bool
}
