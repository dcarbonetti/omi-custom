import AppKit
import CryptoKit
import Foundation

/// Google OAuth for the Drive backup (RFC 8252 native-app flow: loopback redirect + PKCE).
///
/// Uses the user's own OAuth client ("Desktop app" type, created in their Google Cloud project)
/// and the narrow `drive.file` scope: Omi can only see and change files it created itself, never
/// the rest of the user's Drive. The refresh token lives in the Keychain; the short-lived access
/// token only in memory.
actor GoogleDriveAuth {
  static let shared = GoogleDriveAuth()

  static let scopes = [
    "https://www.googleapis.com/auth/drive.file",
    "openid",
    "email",
  ]
  private static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
  private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
  private static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"
  private static let keychainBase = "com.omi.desktop.google-drive"
  private static let refreshTokenAccount = "refresh_token"
  private static let clientSecretAccount = "client_secret"

  enum AuthError: LocalizedError {
    case notConfigured
    case notSignedIn
    case stateMismatch
    case tokenRequestFailed(Int, String)
    case missingToken

    var errorDescription: String? {
      switch self {
      case .notConfigured:
        return "Add your Google OAuth client ID first (Settings → Local-first → Google Drive)."
      case .notSignedIn: return "Sign in to Google Drive first."
      case .stateMismatch: return "The Google sign-in response didn't match this request. Try again."
      case .tokenRequestFailed(let status, let message):
        return "Google sign-in failed (HTTP \(status)): \(message)"
      case .missingToken: return "Google didn't return a token. Try signing in again."
      }
    }
  }

  struct TokenResponse: Decodable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?
    let idToken: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
      case idToken = "id_token"
      case error
      case errorDescription = "error_description"
    }
  }

  private var accessToken: String?
  private var accessTokenExpiry: Date = .distantPast

  private var keychainService: String { DesktopKeychainStore.scopedService(Self.keychainBase) }

  // MARK: Configuration

  static var clientID: String {
    UserDefaults.standard.string(forKey: DefaultsKey.googleDriveClientID)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  static var isConfigured: Bool { !clientID.isEmpty }

  func setClientCredentials(clientID: String, clientSecret: String) {
    UserDefaults.standard.set(
      clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: DefaultsKey.googleDriveClientID)
    let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    if secret.isEmpty {
      DesktopKeychainStore.delete(service: keychainService, account: Self.clientSecretAccount)
    } else {
      DesktopKeychainStore.setString(secret, service: keychainService, account: Self.clientSecretAccount)
    }
  }

  private var clientSecret: String? {
    DesktopKeychainStore.string(service: keychainService, account: Self.clientSecretAccount)
  }

  var isSignedIn: Bool {
    DesktopKeychainStore.string(service: keychainService, account: Self.refreshTokenAccount) != nil
  }

  // MARK: Sign in / out

  /// Opens the browser for consent and stores the refresh token. Returns the account email.
  @discardableResult
  func signIn() async throws -> String? {
    let clientID = Self.clientID
    guard !clientID.isEmpty else { throw AuthError.notConfigured }

    let listener = try await LoopbackCallbackListener.start()
    defer { listener.stop() }
    // Google's loopback redirect for desktop clients: any port, no registration needed.
    let redirectURI = "http://127.0.0.1:\(listener.port)"
    let verifier = try LocalMcpStore.randomURLSafeToken(byteCount: 32)
    let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    let state = try LocalMcpStore.randomURLSafeToken(byteCount: 16)

    var components = URLComponents(string: Self.authorizationEndpoint)
    components?.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      // A refresh token, and a fresh one on every sign-in.
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
    ]
    guard let authURL = components?.url else { throw AuthError.notConfigured }
    _ = await MainActor.run { NSWorkspace.shared.open(authURL) }

    let callback = try await listener.waitForCode(timeoutSeconds: 300)
    guard callback.state == state else { throw AuthError.stateMismatch }

    var form = [
      "grant_type": "authorization_code",
      "code": callback.code,
      "redirect_uri": redirectURI,
      "client_id": clientID,
      "code_verifier": verifier,
    ]
    if let clientSecret { form["client_secret"] = clientSecret }
    let tokens = try await Self.postForm(Self.tokenEndpoint, form: form)
    guard let refresh = tokens.refreshToken, let access = tokens.accessToken else {
      throw AuthError.missingToken
    }
    DesktopKeychainStore.setString(refresh, service: keychainService, account: Self.refreshTokenAccount)
    remember(access: access, expiresIn: tokens.expiresIn)
    let email = tokens.idToken.flatMap(Self.email(fromIDToken:))
    UserDefaults.standard.set(email, forKey: DefaultsKey.googleDriveAccountEmail)
    log("GoogleDrive: signed in\(email.map { " as \($0)" } ?? "")")
    return email
  }

  func signOut() async {
    let refresh = DesktopKeychainStore.string(service: keychainService, account: Self.refreshTokenAccount)
    DesktopKeychainStore.delete(service: keychainService, account: Self.refreshTokenAccount)
    accessToken = nil
    accessTokenExpiry = .distantPast
    UserDefaults.standard.removeObject(forKey: DefaultsKey.googleDriveAccountEmail)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.googleDriveFolderID)
    if let refresh {
      // Best effort: also revoke the grant at Google.
      _ = try? await Self.postForm(Self.revokeEndpoint, form: ["token": refresh])
    }
    log("GoogleDrive: signed out")
  }

  // MARK: Tokens

  /// A valid access token, refreshed when it is within a minute of expiring.
  func validAccessToken(forceRefresh: Bool = false) async throws -> String {
    if !forceRefresh, let accessToken, accessTokenExpiry.timeIntervalSinceNow > 60 {
      return accessToken
    }
    guard let refresh = DesktopKeychainStore.string(service: keychainService, account: Self.refreshTokenAccount)
    else { throw AuthError.notSignedIn }
    let clientID = Self.clientID
    guard !clientID.isEmpty else { throw AuthError.notConfigured }
    var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]
    if let clientSecret { form["client_secret"] = clientSecret }
    let tokens = try await Self.postForm(Self.tokenEndpoint, form: form)
    guard let access = tokens.accessToken else { throw AuthError.missingToken }
    remember(access: access, expiresIn: tokens.expiresIn)
    return access
  }

  private func remember(access: String, expiresIn: Double?) {
    accessToken = access
    accessTokenExpiry = Date().addingTimeInterval(expiresIn ?? 3600)
  }

  // MARK: Helpers

  private static func postForm(_ endpoint: String, form: [String: String]) async throws -> TokenResponse {
    guard let url = URL(string: endpoint) else { throw AuthError.notConfigured }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    request.httpBody = form.map { key, value in
      "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
    }.joined(separator: "&").data(using: .utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
    guard (200..<300).contains(status) else {
      let message = decoded?.errorDescription ?? decoded?.error ?? "unknown error"
      throw AuthError.tokenRequestFailed(status, message)
    }
    // The revoke endpoint answers 200 with an empty body.
    return decoded
      ?? TokenResponse(
        accessToken: nil, refreshToken: nil, expiresIn: nil, idToken: nil, error: nil, errorDescription: nil)
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// The `email` claim of an ID token received directly from Google's token endpoint over TLS
  /// (display only, so the signature is not re-verified here).
  static func email(fromIDToken token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 { payload += "=" }
    guard let data = Data(base64Encoded: payload),
      let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    return claims["email"] as? String
  }
}
