import CryptoKit
import Foundation

/// Pure rendering of the Google Drive backup: what each file is called and what it contains.
///
/// Built from plain snapshots of the API models so it can be tested without a network, and so
/// the on-Drive format does not shift when an API model gains a field. Every conversation is one
/// Markdown file (readable in Drive) plus one JSON file (machine-readable); memories and tasks are
/// one Markdown and one JSON file each.
enum GoogleDriveExport {
  struct Segment: Codable, Equatable, Sendable {
    let speaker: String
    let isUser: Bool
    let start: Double
    let text: String
  }

  struct Conversation: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let emoji: String
    let category: String
    let overview: String
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let updatedAt: Date?
    let source: String?
    let language: String?
    let actionItems: [String]
    let segments: [Segment]
  }

  struct Memory: Codable, Equatable, Sendable {
    let id: String
    let content: String
    let category: String
    let createdAt: Date
    let updatedAt: Date
  }

  struct TaskItem: Codable, Equatable, Sendable {
    let id: String
    let description: String
    let completed: Bool
    let createdAt: Date
    let dueAt: Date?
    let completedAt: Date?
  }

  struct File: Equatable, Sendable {
    /// Stable key for change tracking (`conversations/<id>.md`, `memories.json`, …).
    let key: String
    let folder: Folder
    let name: String
    let mimeType: String
    let data: Data

    var digest: String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
  }

  enum Folder: String, CaseIterable, Sendable {
    case root = ""
    case conversations
  }

  // MARK: Files

  static func files(for conversation: Conversation) -> [File] {
    let base = fileBaseName(for: conversation)
    return [
      File(
        key: "conversations/\(conversation.id).md", folder: .conversations, name: "\(base).md",
        mimeType: "text/markdown", data: Data(markdown(conversation).utf8)),
      File(
        key: "conversations/\(conversation.id).json", folder: .conversations, name: "\(base).json",
        mimeType: "application/json", data: json(conversation)),
    ]
  }

  static func files(memories: [Memory]) -> [File] {
    [
      File(
        key: "memories.md", folder: .root, name: "Memories.md", mimeType: "text/markdown",
        data: Data(markdown(memories: memories).utf8)),
      File(
        key: "memories.json", folder: .root, name: "memories.json", mimeType: "application/json",
        data: json(memories)),
    ]
  }

  static func files(tasks: [TaskItem]) -> [File] {
    [
      File(
        key: "tasks.md", folder: .root, name: "Tasks.md", mimeType: "text/markdown",
        data: Data(markdown(tasks: tasks).utf8)),
      File(key: "tasks.json", folder: .root, name: "tasks.json", mimeType: "application/json", data: json(tasks)),
    ]
  }

  /// `2026-11-19 0930 Weekly planning (abc123)`: sorts by date in Drive, readable, and unique.
  static func fileBaseName(for conversation: Conversation) -> String {
    let date = conversation.startedAt ?? conversation.createdAt
    let title = sanitizedTitle(conversation.title)
    return "\(fileDateFormatter.string(from: date)) \(title) (\(conversation.id.prefix(8)))"
  }

  static func sanitizedTitle(_ raw: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
    let cleaned = raw.components(separatedBy: forbidden).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let title = collapsed.isEmpty ? "Untitled conversation" : collapsed
    return String(title.prefix(80))
  }

  // MARK: Markdown

  static func markdown(_ conversation: Conversation) -> String {
    var lines: [String] = []
    let heading = [conversation.emoji, conversation.title].filter { !$0.isEmpty }.joined(separator: " ")
    lines.append("# \(heading.isEmpty ? "Untitled conversation" : heading)")
    lines.append("")
    let start = conversation.startedAt ?? conversation.createdAt
    var meta = ["**When:** \(displayFormatter.string(from: start))"]
    if let finished = conversation.finishedAt {
      let minutes = max(0, Int(finished.timeIntervalSince(start) / 60))
      meta.append("**Duration:** \(minutes) min")
    }
    if !conversation.category.isEmpty { meta.append("**Category:** \(conversation.category)") }
    if let source = conversation.source, !source.isEmpty { meta.append("**Source:** \(source)") }
    lines.append(meta.joined(separator: " · "))
    if !conversation.overview.isEmpty {
      lines += ["", "## Summary", "", conversation.overview]
    }
    if !conversation.actionItems.isEmpty {
      lines += ["", "## Action items", ""]
      lines += conversation.actionItems.map { "- [ ] \($0)" }
    }
    if !conversation.segments.isEmpty {
      lines += ["", "## Transcript", ""]
      for segment in conversation.segments {
        let who = segment.isUser ? "You" : (segment.speaker.isEmpty ? "Speaker" : segment.speaker)
        lines.append("**\(who)** [\(timestamp(segment.start))]: \(segment.text)")
        lines.append("")
      }
    }
    lines.append("")
    lines.append("<sub>Omi conversation \(conversation.id)</sub>")
    return lines.joined(separator: "\n") + "\n"
  }

  static func markdown(memories: [Memory]) -> String {
    var lines = ["# Memories", "", "\(memories.count) memories, newest first.", ""]
    let grouped = Dictionary(grouping: memories.sorted { $0.createdAt > $1.createdAt }, by: \.category)
    for category in grouped.keys.sorted() {
      lines.append("## \(category.isEmpty ? "Other" : category.capitalized)")
      lines.append("")
      for memory in grouped[category] ?? [] {
        lines.append("- \(memory.content) _(\(dayFormatter.string(from: memory.createdAt)))_")
      }
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  static func markdown(tasks: [TaskItem]) -> String {
    let open = tasks.filter { !$0.completed }.sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    let done = tasks.filter(\.completed).sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    var lines = ["# Tasks", "", "## Open (\(open.count))", ""]
    lines += open.map { task in
      let due = task.dueAt.map { " — due \(dayFormatter.string(from: $0))" } ?? ""
      return "- [ ] \(task.description)\(due)"
    }
    lines += ["", "## Done (\(done.count))", ""]
    lines += done.map { "- [x] \($0.description)" }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  // MARK: JSON

  static func json<T: Encodable>(_ value: T) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(value)) ?? Data("{}".utf8)
  }

  // MARK: Formatting

  static func timestamp(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
  }

  private static let fileDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HHmm"
    return formatter
  }()

  private static let displayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}

// MARK: - Snapshots from API models

extension GoogleDriveExport.Conversation {
  init(_ conversation: ServerConversation) {
    self.init(
      id: conversation.id,
      title: conversation.structured.title,
      emoji: conversation.structured.emoji,
      category: conversation.structured.category,
      overview: conversation.structured.overview,
      createdAt: conversation.createdAt,
      startedAt: conversation.startedAt,
      finishedAt: conversation.finishedAt,
      updatedAt: conversation.updatedAt,
      source: conversation.source?.rawValue,
      language: conversation.language,
      actionItems: conversation.structured.actionItems.filter { !$0.deleted }.map(\.description),
      segments: conversation.transcriptSegments.map {
        GoogleDriveExport.Segment(speaker: $0.speaker ?? "", isUser: $0.isUser, start: $0.start, text: $0.text)
      }
    )
  }
}

extension GoogleDriveExport.Memory {
  init(_ memory: ServerMemory) {
    self.init(
      id: memory.id, content: memory.content, category: memory.category.rawValue,
      createdAt: memory.createdAt, updatedAt: memory.updatedAt)
  }
}

extension GoogleDriveExport.TaskItem {
  init(_ item: TaskActionItem) {
    self.init(
      id: item.id, description: item.description, completed: item.completed,
      createdAt: item.createdAt, dueAt: item.dueAt, completedAt: item.completedAt)
  }
}
