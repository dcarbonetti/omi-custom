import Foundation

/// Pure policy + transition state for cloud ↔ on-device STT fallback.
/// All resolution rules live here so AppState only orchestrates I/O.
struct STTSessionState: Equatable {
  enum ResolvedMode: Equatable {
    case local
    case cloud

    var usesLocalSTT: Bool { self == .local }
  }

  enum FallbackDirection: Equatable {
    case localToCloud
    case cloudToLocal
  }

  /// Sticky for the app run after Parakeet model-load failure (never reset on new recordings).
  private(set) var appRunForceCloud = false
  /// Session sticky: prefer on-device after cloud reconnect exhaustion.
  private(set) var sessionForceLocal = false
  /// One-shot guard: cloud→local fallback already attempted this session.
  private(set) var cloudToLocalFallbackTried = false
  /// Mutex during stop→async-restart fallback choreography.
  private(set) var fallbackInProgress = false
  /// Active transport mode while capture is running (`nil` when stopped).
  var activeMode: ResolvedMode?
  /// Language of the running recording; gates the cloud→local fallback.
  private(set) var activeLanguage: STTLanguageCapability.Selection = .english
  /// Transcription is routed "On this Mac" (`LocalFirstSettings`): the recording runs on-device
  /// and never falls back to a cloud STT socket, whatever the source, plan or wake-word setting.
  private(set) var strictLocal = false

  var useLocalSTT: Bool { activeMode?.usesLocalSTT ?? false }

  /// Reset session-scoped flags when starting a new recording (skipped mid-fallback).
  mutating func prepareForStart() {
    guard !fallbackInProgress else { return }
    cloudToLocalFallbackTried = false
    sessionForceLocal = false
  }

  /// Resolve which STT path to use for a new recording.
  ///
  /// Pendant BLE used to force cloud for named speaker-ID. Identified basic
  /// (non-BYOK) on Apple Silicon now matches mic: local, unnamed. Paid,
  /// unknown, and cache-miss stay on the previous BLE→cloud path.
  ///
  /// `wakeWordNeedsRecognizableName` is the opt-in the wake word needs to work. Ambient
  /// transcription is on-device by default, and the manager that path runs on takes a
  /// language hint and nothing else — `AsrManager.transcribe(_:decoderState:language:)` has
  /// no keyword or vocabulary parameter, so it cannot be told that "Omi" is a word.
  /// FluidAudio does ship term biasing, but only on `SlidingWindowAsrManager`
  /// (`configureVocabularyBoosting(vocabulary:ctcModels:config:)`), which is a different
  /// streaming architecture and pulls a second set of CTC models. That is the upgrade path
  /// out of this flag; it is not a parameter we can pass today. Measured
  /// on one machine, same script and voices, only the lane changed: the phrase was usable
  /// in 12 of 20 utterances on-device against 19 of 20 on the cloud lane, which reaches
  /// `/v4/listen` — and that path prepends "Omi" to the STT keyword vocabulary server-side
  /// (`backend/utils/listen_session_bootstrap.py`), so the recognizer is told the name.
  /// Seven of the eight on-device misses came back as "Only". Because "Only" also opens
  /// ordinary sentences, the parser recovers it only when a command follows
  /// (`WakeWordSegmentParser.commandShapedRenderings`); the 12 of 20 predates that recovery.
  ///
  /// Off by default. It trades on-device transcription for cloud transcription while the
  /// wake word is enabled, which is a privacy and cost decision, not a technical one.
  ///
  /// A `language` no on-device model covers (`STTLanguageCapability`) always resolves to cloud,
  /// even after a cloud→local fallback: a model without the language's tokens emits fluent
  /// text in the wrong language, which is worse than a cloud outage.
  func resolveMode(
    audioSource: AudioSource,
    isAppleSilicon: Bool,
    debugForceCloud: Bool,
    wakeWordNeedsRecognizableName: Bool = false,
    preferLocalOnBasic: Bool = false,
    language: STTLanguageCapability.Selection = .english,
    strictLocal: Bool = false
  ) -> ResolvedMode {
    // Callers check `strictLocalBlockReason` first, so a strict recording only starts where the
    // on-device model can actually serve it.
    if strictLocal { return .local }
    let forceCloud =
      !sessionForceLocal && (debugForceCloud || appRunForceCloud || wakeWordNeedsRecognizableName)
    if !isAppleSilicon || forceCloud || !language.isCoveredOnDevice {
      return .cloud
    }
    if audioSource == .bleDevice && !preferLocalOnBasic {
      return .cloud
    }
    return .local
  }

  mutating func beginRecording(
    audioSource: AudioSource,
    isAppleSilicon: Bool,
    debugForceCloud: Bool,
    wakeWordNeedsRecognizableName: Bool = false,
    preferLocalOnBasic: Bool = false,
    language: STTLanguageCapability.Selection = .english,
    strictLocal: Bool = false
  ) {
    activeLanguage = language
    self.strictLocal = strictLocal
    activeMode = resolveMode(
      audioSource: audioSource,
      isAppleSilicon: isAppleSilicon,
      debugForceCloud: debugForceCloud,
      wakeWordNeedsRecognizableName: wakeWordNeedsRecognizableName,
      preferLocalOnBasic: preferLocalOnBasic,
      language: language,
      strictLocal: strictLocal
    )
  }

  /// Why a strict on-device recording cannot start, or `nil` when it can. Strict mode refuses
  /// rather than sending audio to the cloud.
  static func strictLocalBlockReason(
    isAppleSilicon: Bool,
    language: STTLanguageCapability.Selection
  ) -> String? {
    if !isAppleSilicon {
      return "On-device transcription needs an Apple Silicon Mac."
    }
    if !language.isCoveredOnDevice {
      return
        "The selected transcription language isn't supported on-device. Choose a supported language, or set Transcription to Omi Cloud in Settings → Local-first."
    }
    return nil
  }

  mutating func endRecording() {
    activeMode = nil
  }

  func canBeginLocalToCloudFallback(isTranscribing: Bool) -> Bool {
    isTranscribing && useLocalSTT && !strictLocal && !fallbackInProgress
  }

  mutating func beginLocalToCloudFallback() {
    fallbackInProgress = true
    appRunForceCloud = true
    // Clear a stale session-local preference so resolveMode honors the cloud
    // fallback instead of resolving back to .local.
    sessionForceLocal = false
  }

  func canBeginCloudToLocalFallback(
    isTranscribing: Bool,
    audioSource: AudioSource,
    isAppleSilicon: Bool
  ) -> Bool {
    isTranscribing
      && audioSource != .bleDevice
      && !useLocalSTT
      && isAppleSilicon
      && activeLanguage.isCoveredOnDevice
      && !appRunForceCloud
      && !cloudToLocalFallbackTried
      && !fallbackInProgress
  }

  mutating func beginCloudToLocalFallback() {
    cloudToLocalFallbackTried = true
    fallbackInProgress = true
    sessionForceLocal = true
  }

  mutating func completeFallback() {
    fallbackInProgress = false
  }

  static func debugForceCloudSTT(
    environmentForceCloud: Bool,
    userDefaultsForceCloud: Bool
  ) -> Bool {
    environmentForceCloud || userDefaultsForceCloud
  }
}
