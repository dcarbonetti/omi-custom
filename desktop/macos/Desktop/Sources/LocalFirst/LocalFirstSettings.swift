import Foundation

/// Where an AI-dependent feature runs.
///
/// - `local`: on this Mac. Nothing for that feature leaves the machine.
/// - `omi`: Omi's managed cloud (the upstream default).
/// - `ownAccount`: a cloud provider, billed to the user's own API key (BYOK keys from
///   Settings → Advanced → Developer Keys, sent as `X-BYOK-*` headers).
enum AIRoute: String, CaseIterable, Sendable {
  case local
  case omi
  case ownAccount

  var displayName: String {
    switch self {
    case .local: return "On this Mac"
    case .omi: return "Omi Cloud"
    case .ownAccount: return "My own cloud account"
    }
  }

  static func parse(_ raw: String?) -> AIRoute? {
    guard let raw else { return nil }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "local", "on-device", "ondevice", "mac": return .local
    case "omi", "cloud", "managed": return .omi
    case "own", "ownaccount", "own_account", "byok": return .ownAccount
    default: return nil
    }
  }
}

/// Which on-device engine runs summaries and memories when a feature is routed `local`.
///
/// Persisted through the existing `forceLocalInferenceEngine` switch that
/// `LocalInferenceRuntime` already honors, so there is one source of truth for selection.
enum LocalAIEngine: String, CaseIterable, Sendable {
  /// Apple Intelligence when available, otherwise the local server (upstream default).
  case automatic
  /// Apple's on-device Foundation Model (needs Apple Intelligence enabled).
  case appleIntelligence
  /// An OpenAI-compatible server on this Mac: Ollama, LM Studio, llama.cpp.
  case localServer

  var displayName: String {
    switch self {
    case .automatic: return "Automatic"
    case .appleIntelligence: return "Apple Intelligence"
    case .localServer: return "Ollama / LM Studio"
    }
  }

  /// Value for `LocalInferenceKillSwitches.forceEngineDefaultsKey`; `nil` removes the pin.
  var forcedEngineRawValue: String? {
    switch self {
    case .automatic: return nil
    case .appleIntelligence: return LocalInferenceEngineID.afm.rawValue
    case .localServer: return LocalInferenceEngineID.localServer.rawValue
    }
  }
}

/// Settings for the local-first build: per-feature AI routing and the usage-data opt-in.
///
/// Every value is readable from the process environment (wins, for scripted launches such
/// as `scripts/local-first/run-local.sh`) or from UserDefaults (what Settings writes).
/// Defaults are local-first: on-device transcription and processing, usage data off.
enum LocalFirstSettings {
  static let transcriptionRouteEnvironmentKey = "OMI_TRANSCRIPTION_ROUTE"
  static let processingRouteEnvironmentKey = "OMI_PROCESSING_ROUTE"
  static let shareUsageDataEnvironmentKey = "OMI_SHARE_USAGE_DATA"

  static let defaultTranscriptionRoute: AIRoute = .local
  static let defaultProcessingRoute: AIRoute = .local

  /// Unit tests of upstream code run with empty defaults and expect upstream behavior, so the
  /// local-first defaults apply to the app only. An explicit setting applies everywhere.
  static let isRunningUnderXCTest: Bool =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  // MARK: Transcription

  /// The route to enforce, or `nil` for upstream automatic behavior (only when nothing is set
  /// and `localFirstDefault` is false, i.e. under unit tests).
  static func configuredTranscriptionRoute(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard,
    localFirstDefault: Bool = !isRunningUnderXCTest
  ) -> AIRoute? {
    AIRoute.parse(environment[transcriptionRouteEnvironmentKey])
      ?? AIRoute.parse(defaults.string(forKey: DefaultsKey.localFirstTranscriptionRoute))
      ?? (localFirstDefault ? defaultTranscriptionRoute : nil)
  }

  /// The route Settings shows.
  static func transcriptionRoute(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard
  ) -> AIRoute {
    configuredTranscriptionRoute(environment: environment, defaults: defaults, localFirstDefault: true)
      ?? defaultTranscriptionRoute
  }

  static func setTranscriptionRoute(_ route: AIRoute, defaults: UserDefaults = .standard) {
    defaults.set(route.rawValue, forKey: DefaultsKey.localFirstTranscriptionRoute)
  }

  /// Strict on-device transcription: never open a cloud STT socket, not even as a fallback.
  static func isStrictLocalTranscription(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard,
    localFirstDefault: Bool = !isRunningUnderXCTest
  ) -> Bool {
    configuredTranscriptionRoute(
      environment: environment, defaults: defaults, localFirstDefault: localFirstDefault) == .local
  }

  // MARK: Summaries, memories, action items

  /// The route to enforce, or `nil` for upstream behavior (see `configuredTranscriptionRoute`).
  static func configuredProcessingRoute(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard,
    localFirstDefault: Bool = !isRunningUnderXCTest
  ) -> AIRoute? {
    AIRoute.parse(environment[processingRouteEnvironmentKey])
      ?? AIRoute.parse(defaults.string(forKey: DefaultsKey.localFirstProcessingRoute))
      ?? (localFirstDefault ? defaultProcessingRoute : nil)
  }

  /// The route Settings shows.
  static func processingRoute(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard
  ) -> AIRoute {
    configuredProcessingRoute(environment: environment, defaults: defaults, localFirstDefault: true)
      ?? defaultProcessingRoute
  }

  /// Background AI (proactive assistants, connector synthesis, cloud embeddings, web search) stays
  /// off the cloud unless the user opts in with Cloud-assisted features.
  static func backgroundAIStaysLocal() -> Bool {
    configuredProcessingRoute() == .local
  }

  static func setProcessingRoute(_ route: AIRoute, defaults: UserDefaults = .standard) {
    defaults.set(route.rawValue, forKey: DefaultsKey.localFirstProcessingRoute)
  }

  // MARK: Local engine

  static func localEngine(defaults: UserDefaults = .standard) -> LocalAIEngine {
    defaults.string(forKey: DefaultsKey.localFirstLocalEngine).flatMap(LocalAIEngine.init(rawValue:))
      ?? .automatic
  }

  static func setLocalEngine(_ engine: LocalAIEngine, defaults: UserDefaults = .standard) {
    defaults.set(engine.rawValue, forKey: DefaultsKey.localFirstLocalEngine)
    if let pinned = engine.forcedEngineRawValue {
      defaults.set(pinned, forKey: LocalInferenceKillSwitches.forceEngineDefaultsKey)
    } else {
      defaults.removeObject(forKey: LocalInferenceKillSwitches.forceEngineDefaultsKey)
    }
  }

  // MARK: Usage data

  /// Product analytics (PostHog, incl. session replay) and remote client telemetry.
  /// Off unless the user opts in.
  static func shareUsageData(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard
  ) -> Bool {
    if let raw = environment[shareUsageDataEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    {
      return FreeTierLocalProcessingFlag.isTruthy(raw)
    }
    return defaults.bool(forKey: DefaultsKey.localFirstShareUsageData)
  }

  static func setShareUsageData(_ enabled: Bool, defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: DefaultsKey.localFirstShareUsageData)
  }

  // MARK: Backend

  /// True when the desktop backend URL points at this Mac (the local stack from
  /// `scripts/local-first/run-local.sh`), so server-side processing also stays local.
  static func backendIsLocal(baseURL: String?) -> Bool {
    guard let baseURL, let host = URL(string: baseURL)?.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }
}
