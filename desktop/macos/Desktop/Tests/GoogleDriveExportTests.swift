import XCTest

@testable import Omi_Computer

final class GoogleDriveExportTests: XCTestCase {
  private func conversation(title: String = "Weekly planning", segments: Int = 2) -> GoogleDriveExport.Conversation {
    let start = Date(timeIntervalSince1970: 1_763_544_600)  // fixed instant
    return GoogleDriveExport.Conversation(
      id: "abc12345def",
      title: title,
      emoji: "🗓️",
      category: "work",
      overview: "Planned the week.",
      createdAt: start,
      startedAt: start,
      finishedAt: start.addingTimeInterval(25 * 60),
      updatedAt: nil,
      source: "desktop",
      language: "en",
      actionItems: ["Send the agenda"],
      segments: (0..<segments).map {
        GoogleDriveExport.Segment(speaker: "SPEAKER_01", isUser: $0 == 0, start: Double($0 * 65), text: "Line \($0)")
      }
    )
  }

  func testConversationProducesMarkdownAndJSONInConversationsFolder() {
    let files = GoogleDriveExport.files(for: conversation())
    XCTAssertEqual(files.map(\.key), ["conversations/abc12345def.md", "conversations/abc12345def.json"])
    XCTAssertTrue(files.allSatisfy { $0.folder == .conversations })
    XCTAssertTrue(files[0].name.hasSuffix("Weekly planning (abc12345).md"))
    XCTAssertEqual(files[0].mimeType, "text/markdown")
    XCTAssertEqual(files[1].mimeType, "application/json")
  }

  func testMarkdownCarriesSummaryActionItemsAndTranscript() {
    let markdown = GoogleDriveExport.markdown(conversation())
    XCTAssertTrue(markdown.hasPrefix("# 🗓️ Weekly planning\n"))
    XCTAssertTrue(markdown.contains("**Duration:** 25 min"))
    XCTAssertTrue(markdown.contains("## Summary\n\nPlanned the week."))
    XCTAssertTrue(markdown.contains("- [ ] Send the agenda"))
    XCTAssertTrue(markdown.contains("**You** [00:00:00]: Line 0"))
    XCTAssertTrue(markdown.contains("**SPEAKER_01** [00:01:05]: Line 1"))
  }

  func testJSONRoundTrips() throws {
    let original = conversation()
    let data = GoogleDriveExport.json(original)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    XCTAssertEqual(try decoder.decode(GoogleDriveExport.Conversation.self, from: data), original)
  }

  func testTitlesAreSafeFileNames() {
    XCTAssertEqual(GoogleDriveExport.sanitizedTitle("a/b:c*d?\"e\"<f>|g\nh"), "a b c d e f g h")
    XCTAssertEqual(GoogleDriveExport.sanitizedTitle("   "), "Untitled conversation")
    XCTAssertEqual(GoogleDriveExport.sanitizedTitle(String(repeating: "x", count: 200)).count, 80)
  }

  func testDigestIsStableAndChangesWithContent() {
    let first = GoogleDriveExport.files(for: conversation())[0].digest
    XCTAssertEqual(first, GoogleDriveExport.files(for: conversation())[0].digest)
    XCTAssertNotEqual(first, GoogleDriveExport.files(for: conversation(segments: 3))[0].digest)
  }

  func testMemoriesAndTasksMarkdown() {
    let now = Date(timeIntervalSince1970: 1_763_544_600)
    let memories = GoogleDriveExport.markdown(memories: [
      GoogleDriveExport.Memory(id: "m1", content: "Likes tea", category: "interesting", createdAt: now, updatedAt: now)
    ])
    XCTAssertTrue(memories.contains("## Interesting"))
    XCTAssertTrue(memories.contains("- Likes tea"))

    let tasks = GoogleDriveExport.markdown(tasks: [
      GoogleDriveExport.TaskItem(
        id: "t1", description: "Book flights", completed: false, createdAt: now, dueAt: nil, completedAt: nil),
      GoogleDriveExport.TaskItem(
        id: "t2", description: "Pay rent", completed: true, createdAt: now, dueAt: nil, completedAt: now),
    ])
    XCTAssertTrue(tasks.contains("## Open (1)\n\n- [ ] Book flights"))
    XCTAssertTrue(tasks.contains("## Done (1)\n\n- [x] Pay rent"))
  }

  func testStableHashIsDeterministic() {
    XCTAssertEqual(GoogleDriveSyncEngine.stableHash("omi"), GoogleDriveSyncEngine.stableHash("omi"))
    XCTAssertNotEqual(GoogleDriveSyncEngine.stableHash("omi"), GoogleDriveSyncEngine.stableHash("omj"))
  }

  func testEmailFromIDToken() {
    // header.payload.signature with payload {"email":"me@example.com"}
    let payload = GoogleDriveAuth.base64URL(Data(#"{"email":"me@example.com"}"#.utf8))
    XCTAssertEqual(GoogleDriveAuth.email(fromIDToken: "e30.\(payload).sig"), "me@example.com")
    XCTAssertNil(GoogleDriveAuth.email(fromIDToken: "garbage"))
  }
}
