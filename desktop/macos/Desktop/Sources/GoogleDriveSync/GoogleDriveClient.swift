import Foundation

/// Minimal Google Drive v3 client for the backup: find-or-create folders and create/update files.
///
/// Under the `drive.file` scope every query only sees files this app created, so a name lookup
/// cannot pick up an unrelated folder of the user's.
struct GoogleDriveClient: Sendable {
  enum DriveError: LocalizedError {
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
      switch self {
      case .http(let status, let message): return "Google Drive request failed (HTTP \(status)): \(message)"
      case .invalidResponse: return "Google Drive returned an unexpected response."
      }
    }

    var status: Int? {
      if case .http(let status, _) = self { return status }
      return nil
    }
  }

  private struct DriveFile: Decodable, Sendable {
    let id: String
  }

  private struct FileList: Decodable, Sendable {
    let files: [DriveFile]
  }

  static let folderMimeType = "application/vnd.google-apps.folder"
  private static let apiBase = "https://www.googleapis.com/drive/v3"
  private static let uploadBase = "https://www.googleapis.com/upload/drive/v3"

  let auth: GoogleDriveAuth

  init(auth: GoogleDriveAuth = .shared) {
    self.auth = auth
  }

  // MARK: Folders

  /// The folder named `name` under `parentID` (or My Drive root), created when missing.
  func ensureFolder(named name: String, parentID: String?) async throws -> String {
    let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    var query = "name = '\(escaped)' and mimeType = '\(Self.folderMimeType)' and trashed = false"
    if let parentID { query += " and '\(parentID)' in parents" }
    var components = URLComponents(string: "\(Self.apiBase)/files")
    components?.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "fields", value: "files(id)"),
      URLQueryItem(name: "pageSize", value: "1"),
    ]
    guard let listURL = components?.url else { throw DriveError.invalidResponse }
    let listData = try await send { token in
      var request = URLRequest(url: listURL)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      return request
    }
    if let existing = try JSONDecoder().decode(FileList.self, from: listData).files.first {
      return existing.id
    }

    var metadata: [String: Any] = ["name": name, "mimeType": Self.folderMimeType]
    if let parentID { metadata["parents"] = [parentID] }
    let body = try JSONSerialization.data(withJSONObject: metadata)
    guard let createURL = URL(string: "\(Self.apiBase)/files?fields=id") else { throw DriveError.invalidResponse }
    let created = try await send { token in
      var request = URLRequest(url: createURL)
      request.httpMethod = "POST"
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
      return request
    }
    return try JSONDecoder().decode(DriveFile.self, from: created).id
  }

  // MARK: Files

  /// Uploads `data` as a new file, or replaces the content of `existingID`. A file the user
  /// deleted in Drive (404) is created again. Returns the file id.
  func upsertFile(
    name: String, mimeType: String, data: Data, parentID: String, existingID: String?
  ) async throws -> String {
    if let existingID {
      do {
        return try await upload(
          name: name, mimeType: mimeType, data: data, parentID: nil, method: "PATCH",
          path: "/files/\(existingID)")
      } catch let error as DriveError where error.status == 404 {
        log("GoogleDrive: \(name) was removed in Drive — uploading it again")
      }
    }
    return try await upload(
      name: name, mimeType: mimeType, data: data, parentID: parentID, method: "POST", path: "/files")
  }

  private func upload(
    name: String, mimeType: String, data: Data, parentID: String?, method: String, path: String
  ) async throws -> String {
    var metadata: [String: Any] = ["name": name, "mimeType": mimeType]
    if let parentID { metadata["parents"] = [parentID] }
    let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
    let boundary = "omi-\(UUID().uuidString)"
    var body = Data()
    body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
    body.append(metadataJSON)
    body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
    body.append(data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    guard let url = URL(string: "\(Self.uploadBase)\(path)?uploadType=multipart&fields=id") else {
      throw DriveError.invalidResponse
    }
    let payload = body
    let response = try await send { token in
      var request = URLRequest(url: url)
      request.httpMethod = method
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      request.httpBody = payload
      return request
    }
    return try JSONDecoder().decode(DriveFile.self, from: response).id
  }

  // MARK: Transport

  /// Sends with a valid token; on 401 refreshes once and retries.
  private func send(_ makeRequest: @Sendable (String) -> URLRequest) async throws -> Data {
    var token = try await auth.validAccessToken()
    for attempt in 0..<2 {
      let (data, response) = try await URLSession.shared.data(for: makeRequest(token))
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if (200..<300).contains(status) { return data }
      if status == 401, attempt == 0 {
        token = try await auth.validAccessToken(forceRefresh: true)
        continue
      }
      let message = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
      throw DriveError.http(status, message)
    }
    throw DriveError.invalidResponse
  }
}
