import Combine
import Foundation

/// Backs up conversations, memories and tasks to the user's own Google Drive.
///
/// Layout in Drive (only files this app created are visible to it, `drive.file`):
///
///     Omi Backup/
///       Memories.md, memories.json
///       Tasks.md, tasks.json
///       Conversations/
///         2026-11-19 0930 Weekly planning (abc12345).md / .json
///
/// Incremental: a conversation is fetched and uploaded again only when it changed, and a file is
/// re-uploaded only when its bytes changed. Progress is saved after every conversation, so an
/// interrupted run resumes where it stopped. Runs every 30 minutes while enabled and signed in,
/// and on demand from Settings.
@MainActor
final class GoogleDriveSyncService: ObservableObject {
  static let shared = GoogleDriveSyncService()

  enum Phase: Equatable {
    case idle
    case syncing(String)
    case failed(String)
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var isSignedIn = false
  @Published private(set) var accountEmail: String?
  @Published private(set) var lastSyncAt: Date?
  @Published private(set) var lastSummary: String?
  @Published var isEnabled: Bool {
    didSet {
      UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.googleDriveSyncEnabled)
      if isEnabled { syncSoon() }
    }
  }

  static let interval: TimeInterval = 30 * 60
  private var timer: Timer?
  private var running: Task<Void, Never>?

  private init() {
    isEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.googleDriveSyncEnabled)
    accountEmail = UserDefaults.standard.string(forKey: DefaultsKey.googleDriveAccountEmail)
    let last = UserDefaults.standard.double(forKey: DefaultsKey.googleDriveLastSyncAt)
    lastSyncAt = last > 0 ? Date(timeIntervalSince1970: last) : nil
  }

  /// Called once at launch: refresh sign-in state and schedule periodic runs.
  func start() {
    Task { await refreshSignInState() }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
      Task { @MainActor in GoogleDriveSyncService.shared.syncIfDue() }
    }
    // First run shortly after launch, once auth and the backend are up.
    Task {
      try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
      GoogleDriveSyncService.shared.syncIfDue()
    }
  }

  func refreshSignInState() async {
    isSignedIn = await GoogleDriveAuth.shared.isSignedIn
    accountEmail = UserDefaults.standard.string(forKey: DefaultsKey.googleDriveAccountEmail)
  }

  // MARK: Account

  func saveClientCredentials(clientID: String, clientSecret: String) async {
    await GoogleDriveAuth.shared.setClientCredentials(clientID: clientID, clientSecret: clientSecret)
  }

  func signIn() async {
    phase = .syncing("Waiting for Google sign-in in your browser…")
    do {
      accountEmail = try await GoogleDriveAuth.shared.signIn()
      isSignedIn = true
      phase = .idle
      isEnabled = true
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  func signOut() async {
    running?.cancel()
    await GoogleDriveAuth.shared.signOut()
    isSignedIn = false
    accountEmail = nil
    isEnabled = false
    phase = .idle
  }

  // MARK: Sync

  func syncIfDue() {
    guard isEnabled, isSignedIn else { return }
    if let lastSyncAt, Date().timeIntervalSince(lastSyncAt) < Self.interval - 60 { return }
    syncNow()
  }

  private func syncSoon() {
    Task {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      GoogleDriveSyncService.shared.syncNow()
    }
  }

  func syncNow() {
    guard running == nil else { return }
    guard isSignedIn else {
      phase = .failed(GoogleDriveAuth.AuthError.notSignedIn.localizedDescription)
      return
    }
    guard let owner = RuntimeOwnerIdentity.currentOwnerId() else {
      phase = .failed("Sign in to Omi first.")
      return
    }
    phase = .syncing("Starting…")
    // Inherits the main actor: state below is assigned directly after each await.
    running = Task {
      let engine = GoogleDriveSyncEngine(ownerID: owner)
      do {
        let summary = try await engine.run { message in
          await MainActor.run { GoogleDriveSyncService.shared.phase = .syncing(message) }
        }
        let now = Date()
        lastSyncAt = now
        lastSummary = summary.description
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: DefaultsKey.googleDriveLastSyncAt)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.googleDriveLastError)
        phase = .idle
        log("GoogleDrive: sync complete — \(summary.description)")
      } catch is CancellationError {
        phase = .idle
      } catch {
        let message = error.localizedDescription
        log("GoogleDrive: sync failed — \(message)")
        UserDefaults.standard.set(message, forKey: DefaultsKey.googleDriveLastError)
        phase = .failed(message)
      }
      running = nil
    }
  }
}

// MARK: - Engine

/// One sync run. Not on the main actor: it pages the API and uploads.
actor GoogleDriveSyncEngine {
  struct Summary: Sendable, CustomStringConvertible {
    var conversationsUploaded = 0
    var conversationsUnchanged = 0
    var filesUploaded = 0

    var description: String {
      "\(conversationsUploaded) conversation(s) backed up, \(conversationsUnchanged) unchanged, "
        + "\(filesUploaded) file(s) written"
    }
  }

  struct FileRecord: Codable, Sendable {
    var id: String
    var digest: String
  }

  struct State: Codable, Sendable {
    var rootFolderID: String?
    var conversationsFolderID: String?
    /// Change marker per conversation id (updated-at, or created-at plus title/summary hash).
    var conversationMarkers: [String: String] = [:]
    /// Drive file per export key.
    var files: [String: FileRecord] = [:]
  }

  static let rootFolderName = "Omi Backup"
  static let conversationsFolderName = "Conversations"
  private static let pageSize = 100
  private static let maxConversations = 20_000

  private let ownerID: String
  private let api: APIClient
  private let drive: GoogleDriveClient
  private var state: State

  init(ownerID: String, api: APIClient = .shared, drive: GoogleDriveClient = GoogleDriveClient()) {
    self.ownerID = ownerID
    self.api = api
    self.drive = drive
    self.state = Self.loadState(ownerID: ownerID)
  }

  func run(progress: @Sendable (String) async -> Void) async throws -> Summary {
    var summary = Summary()
    let root = try await folder(\.rootFolderID, name: Self.rootFolderName, parent: nil)
    let conversationsFolder = try await folder(
      \.conversationsFolderID, name: Self.conversationsFolderName, parent: root)

    // Conversations, newest first.
    var offset = 0
    while offset < Self.maxConversations {
      try Task.checkCancellation()
      let page = try await api.getConversations(limit: Self.pageSize, offset: offset)
      for listed in page {
        try Task.checkCancellation()
        let marker = Self.marker(for: listed)
        let known = state.conversationMarkers[listed.id] == marker
          && state.files["conversations/\(listed.id).md"] != nil
        if known {
          summary.conversationsUnchanged += 1
          continue
        }
        await progress("Backing up \(GoogleDriveExport.sanitizedTitle(listed.structured.title))…")
        // The list may omit transcripts; the single-conversation read includes them.
        let full: ServerConversation
        if listed.transcriptSegmentsIncluded {
          full = listed
        } else {
          full = try await api.getConversation(id: listed.id)
        }
        let files = GoogleDriveExport.files(for: GoogleDriveExport.Conversation(full))
        summary.filesUploaded += try await upload(files, root: root, conversations: conversationsFolder)
        state.conversationMarkers[listed.id] = marker
        summary.conversationsUploaded += 1
        saveState()
      }
      if page.count < Self.pageSize { break }
      offset += page.count
    }

    // Memories.
    await progress("Backing up memories…")
    var memories: [GoogleDriveExport.Memory] = []
    var memoryOffset = 0
    while true {
      try Task.checkCancellation()
      let page = try await api.getMemories(limit: 500, offset: memoryOffset)
      memories += page.map(GoogleDriveExport.Memory.init)
      if page.count < 500 { break }
      memoryOffset += page.count
    }
    summary.filesUploaded += try await upload(
      GoogleDriveExport.files(memories: memories), root: root, conversations: conversationsFolder)

    // Tasks.
    await progress("Backing up tasks…")
    var tasks: [GoogleDriveExport.TaskItem] = []
    var taskOffset = 0
    while true {
      try Task.checkCancellation()
      let page = try await api.getActionItems(limit: 500, offset: taskOffset)
      tasks += page.items.map(GoogleDriveExport.TaskItem.init)
      if !page.hasMore || page.items.isEmpty { break }
      taskOffset += page.items.count
    }
    summary.filesUploaded += try await upload(
      GoogleDriveExport.files(tasks: tasks), root: root, conversations: conversationsFolder)

    saveState()
    return summary
  }

  // MARK: Helpers

  private func folder(_ keyPath: WritableKeyPath<State, String?>, name: String, parent: String?) async throws
    -> String
  {
    if let cached = state[keyPath: keyPath] { return cached }
    let id = try await drive.ensureFolder(named: name, parentID: parent)
    state[keyPath: keyPath] = id
    saveState()
    return id
  }

  /// Uploads files whose bytes changed. Returns how many were written.
  private func upload(_ files: [GoogleDriveExport.File], root: String, conversations: String) async throws -> Int {
    var written = 0
    for file in files {
      let digest = file.digest
      let existing = state.files[file.key]
      if existing?.digest == digest { continue }
      let parent = file.folder == .conversations ? conversations : root
      let id = try await drive.upsertFile(
        name: file.name, mimeType: file.mimeType, data: file.data, parentID: parent, existingID: existing?.id)
      state.files[file.key] = FileRecord(id: id, digest: digest)
      written += 1
    }
    return written
  }

  static func marker(for conversation: ServerConversation) -> String {
    if let updated = conversation.updatedAt {
      return "u\(Int(updated.timeIntervalSince1970 * 1000))"
    }
    let content = conversation.structured.title + "\u{1F}" + conversation.structured.overview
    return "c\(Int(conversation.createdAt.timeIntervalSince1970))-\(content.utf8.count)-\(stableHash(content))"
  }

  /// FNV-1a, so markers are stable across launches (`hashValue` is seeded per process).
  static func stableHash(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }

  // MARK: Persistence

  private static func stateURL(ownerID: String) -> URL? {
    guard
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    let bundle = Bundle.main.bundleIdentifier ?? "com.omi.desktop"
    let safeOwner = ownerID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return base.appendingPathComponent(bundle, isDirectory: true)
      .appendingPathComponent("GoogleDriveSync", isDirectory: true)
      .appendingPathComponent("state-\(safeOwner).json")
  }

  private static func loadState(ownerID: String) -> State {
    guard let url = stateURL(ownerID: ownerID), let data = try? Data(contentsOf: url),
      let state = try? JSONDecoder().decode(State.self, from: data)
    else { return State() }
    return state
  }

  private func saveState() {
    guard let url = Self.stateURL(ownerID: ownerID), let data = try? JSONEncoder().encode(state) else { return }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try data.write(to: url, options: [.atomic])
    } catch {
      log("GoogleDrive: could not save sync state — \(error.localizedDescription)")
    }
  }
}
