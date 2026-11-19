import AppKit
import OmiTheme
import SwiftUI

/// Settings → Local-first: where each AI feature runs, usage-data sharing, and Google Drive backup.
struct LocalFirstSettingsView: View {
  @State private var transcriptionRoute = LocalFirstSettings.transcriptionRoute()
  @State private var processingRoute = LocalFirstSettings.processingRoute()
  @State private var localEngine = LocalFirstSettings.localEngine()
  @State private var shareUsageData = LocalFirstSettings.shareUsageData()
  @State private var cloudAssistOn = AIProvider.localCloudAssistMode == .cloud
  @State private var backendURL = ""
  @AppStorage("chatBridgeMode") private var chatBridgeMode = AIProvider.piMono.bridgeModeRawValue

  @ObservedObject private var drive = GoogleDriveSyncService.shared
  @State private var driveClientID = GoogleDriveAuth.clientID
  @State private var driveClientSecret = ""
  @State private var driveCredentialsSaved = false

  private var chatProviderName: String {
    AIProvider.from(bridgeMode: chatBridgeMode)?.displayName ?? chatBridgeMode
  }

  private var backendIsLocal: Bool { LocalFirstSettings.backendIsLocal(baseURL: backendURL) }

  var body: some View {
    VStack(alignment: .leading, spacing: OmiSpacing.xl) {
      overviewCard
      routesCard
      localEngineCard
      privacyCard
      driveCard
    }
    .task {
      backendURL = await APIClient.shared.baseURL
      await drive.refreshSignInState()
    }
  }

  // MARK: Overview

  private var overviewCard: some View {
    card {
      header(icon: "lock.laptopcomputer", title: "Where your data goes")
      statusRow(
        ok: backendIsLocal,
        okText: "Backend: this Mac (\(backendURL))",
        badText: "Backend: Omi Cloud (\(backendURL.isEmpty ? "…" : backendURL)). Conversations are stored on "
          + "Omi's servers. Run scripts/local-first/omi-local to keep them on this Mac.")
      statusRow(
        ok: transcriptionRoute == .local,
        okText: "Transcription: on this Mac, never sent to the cloud",
        badText: "Transcription: \(transcriptionRoute.displayName)")
      statusRow(
        ok: processingRoute == .local,
        okText: "Summaries & memories: on this Mac",
        badText: "Summaries & memories: \(processingRoute.displayName)")
      statusRow(
        ok: chatBridgeMode == AIProvider.local.bridgeModeRawValue,
        okText: "Chat: your local model",
        badText: "Chat: \(chatProviderName) (change under Floating Bar → AI Provider)")
      statusRow(ok: !shareUsageData, okText: "Usage analytics: off", badText: "Usage analytics: shared with Omi")
      Button("Keep everything on this Mac") { useLocalForEverything() }
        .padding(.top, OmiSpacing.xs)
    }
  }

  // MARK: Routes

  private var routesCard: some View {
    card {
      header(icon: "arrow.triangle.branch", title: "Where AI runs")
      routePicker(
        title: "Transcription",
        detail: transcriptionDetail,
        selection: Binding(
          get: { transcriptionRoute },
          set: { route in
            transcriptionRoute = route
            LocalFirstSettings.setTranscriptionRoute(route)
          }))
      routePicker(
        title: "Summaries, memories & tasks",
        detail: processingDetail,
        selection: Binding(
          get: { processingRoute },
          set: { route in
            processingRoute = route
            LocalFirstSettings.setProcessingRoute(route)
          }))
      VStack(alignment: .leading, spacing: OmiSpacing.xs) {
        Text("Chat")
          .scaledFont(size: OmiType.body, weight: .medium)
          .foregroundColor(Ink.primary)
        caption(
          "Chosen under Floating Bar → AI Provider: Local (your model), Omi AI (Omi Cloud), or Claude "
            + "(your own account). Currently: \(chatProviderName).")
      }
      Toggle(
        isOn: Binding(
          get: { cloudAssistOn },
          set: { on in
            cloudAssistOn = on
            UserDefaults.standard.set(
              (on ? AIProvider.CloudAssistMode.cloud : .off).rawValue, forKey: AIProvider.cloudAssistModeKey)
          })
      ) {
        VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
          Text("Cloud-assisted features")
            .scaledFont(size: OmiType.body, weight: .medium)
            .foregroundColor(Ink.primary)
          caption(
            "Proactive assistants, live notes, dictation polish, screen-history search embeddings, connector "
              + "summaries and web search use a cloud model. Off keeps them from sending anything while AI is local.")
        }
      }
    }
  }

  private var transcriptionDetail: String {
    switch transcriptionRoute {
    case .local:
      return "Parakeet on the Neural Engine. Audio never leaves this Mac, with no cloud fallback. Push-to-talk "
        + "types on-device; voice questions are kept for you to send rather than answered by the cloud voice model."
    case .omi:
      return "Streams audio to Omi's transcription service."
    case .ownAccount:
      return "Streams audio through Omi's backend to Deepgram with your own key "
        + "(AI & Automation → Model Provider Keys)."
    }
  }

  private var processingDetail: String {
    switch processingRoute {
    case .local:
      return backendIsLocal
        ? "Summaries run on this Mac, and your local backend sends its own AI work to your local model."
        : "This Mac writes its own summary for every conversation. Omi's servers still process conversations "
          + "they store until you run the local backend."
    case .omi:
      return "Omi Cloud writes summaries, memories and tasks."
    case .ownAccount:
      return "Omi's backend uses your own OpenAI / Anthropic / Gemini key (AI & Automation → Model Provider Keys)."
    }
  }

  // MARK: Local engine

  private var localEngineCard: some View {
    card {
      header(icon: "cpu", title: "Local model")
      Picker(
        "Engine",
        selection: Binding(
          get: { localEngine },
          set: { engine in
            localEngine = engine
            LocalFirstSettings.setLocalEngine(engine)
          })
      ) {
        ForEach(LocalAIEngine.allCases, id: \.self) { engine in
          Text(engine.displayName).tag(engine)
        }
      }
      .pickerStyle(.segmented)
      caption(localEngineDetail)
      caption(
        "Server: \(LocalInferenceKillSwitches.localServerURL().absoluteString) · Model: "
          + "\(LocalInferenceKillSwitches.localServerModel()). Set both under Floating Bar → AI Provider → Local.")
    }
  }

  private var localEngineDetail: String {
    switch localEngine {
    case .automatic:
      return "Apple Intelligence when it's available on this Mac, otherwise your Ollama / LM Studio server."
    case .appleIntelligence:
      return "Apple's on-device model. Needs Apple Intelligence turned on in System Settings."
    case .localServer:
      return "Any OpenAI-compatible server on this Mac: Ollama (port 11434) or LM Studio (port 1234)."
    }
  }

  // MARK: Privacy

  private var privacyCard: some View {
    card {
      header(icon: "hand.raised", title: "Data collection")
      Toggle(
        isOn: Binding(
          get: { shareUsageData },
          set: { on in
            shareUsageData = on
            LocalFirstSettings.setShareUsageData(on)
            AnalyticsManager.shared.applyUsageDataPreference()
          })
      ) {
        VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
          Text("Share usage data with Omi")
            .scaledFont(size: OmiType.body, weight: .medium)
            .foregroundColor(Ink.primary)
          caption(
            "Product analytics (PostHog, including session replay) and app telemetry. Off by default; "
              + "turning it off also discards telemetry that hasn't been sent yet.")
        }
      }
    }
  }

  // MARK: Google Drive

  private var driveCard: some View {
    card {
      header(icon: "externaldrive.badge.icloud", title: "Google Drive backup")
      caption(
        "Copies your conversations (with transcripts), memories and tasks as Markdown and JSON into an "
          + "“Omi Backup” folder in your Drive every 30 minutes. Omi can only see files it created there.")

      if !drive.isSignedIn {
        VStack(alignment: .leading, spacing: OmiSpacing.sm) {
          caption(
            "Uses your own Google OAuth client (Desktop app). See scripts/local-first/README.md → Google Drive.")
          TextField("OAuth client ID (…apps.googleusercontent.com)", text: $driveClientID)
            .textFieldStyle(.roundedBorder)
          SecureField("Client secret", text: $driveClientSecret)
            .textFieldStyle(.roundedBorder)
          HStack(spacing: OmiSpacing.md) {
            Button(driveCredentialsSaved ? "Saved" : "Save") {
              Task {
                await drive.saveClientCredentials(clientID: driveClientID, clientSecret: driveClientSecret)
                driveCredentialsSaved = true
              }
            }
            .disabled(driveClientID.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Sign in with Google") {
              Task {
                await drive.saveClientCredentials(clientID: driveClientID, clientSecret: driveClientSecret)
                await drive.signIn()
              }
            }
            .disabled(driveClientID.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
      } else {
        VStack(alignment: .leading, spacing: OmiSpacing.sm) {
          Text("Signed in\(drive.accountEmail.map { " as \($0)" } ?? "")")
            .scaledFont(size: OmiType.body, weight: .medium)
            .foregroundColor(Ink.primary)
          Toggle("Back up automatically", isOn: $drive.isEnabled)
          HStack(spacing: OmiSpacing.md) {
            Button("Back up now") { drive.syncNow() }
              .disabled(isSyncing)
            Button("Open Google Drive") {
              if let url = URL(string: "https://drive.google.com/drive/my-drive") { NSWorkspace.shared.open(url) }
            }
            Button("Sign out") { Task { await drive.signOut() } }
          }
          if let lastSyncAt = drive.lastSyncAt {
            caption(
              "Last backup: \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))"
                + (drive.lastSummary.map { " — \($0)" } ?? ""))
          }
        }
      }
      switch drive.phase {
      case .idle:
        EmptyView()
      case .syncing(let message):
        caption(message)
      case .failed(let message):
        Text(message)
          .scaledFont(size: OmiType.caption)
          .foregroundColor(SettingsInk.notice)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var isSyncing: Bool {
    if case .syncing = drive.phase { return true }
    return false
  }

  // MARK: Actions

  private func useLocalForEverything() {
    transcriptionRoute = .local
    processingRoute = .local
    shareUsageData = false
    cloudAssistOn = false
    LocalFirstSettings.setTranscriptionRoute(.local)
    LocalFirstSettings.setProcessingRoute(.local)
    LocalFirstSettings.setShareUsageData(false)
    UserDefaults.standard.set(AIProvider.CloudAssistMode.off.rawValue, forKey: AIProvider.cloudAssistModeKey)
    AnalyticsManager.shared.applyUsageDataPreference()
  }

  // MARK: Building blocks

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: OmiSpacing.md) { content() }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(OmiSpacing.md)
      .settingsGlassCard()
  }

  private func header(icon: String, title: String) -> some View {
    HStack(spacing: OmiSpacing.sm) {
      Image(systemName: icon)
        .scaledFont(size: OmiType.subheading)
        .foregroundColor(Ink.secondary)
      Text(title)
        .scaledFont(size: OmiType.subheading, weight: .medium)
        .foregroundColor(Ink.primary)
      Spacer()
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .scaledFont(size: OmiType.caption)
      .foregroundColor(Ink.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func statusRow(ok: Bool, okText: String, badText: String) -> some View {
    HStack(alignment: .top, spacing: OmiSpacing.sm) {
      Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
        .scaledFont(size: OmiType.body)
        .foregroundColor(ok ? Ink.primary : SettingsInk.notice)
      Text(ok ? okText : badText)
        .scaledFont(size: OmiType.caption)
        .foregroundColor(Ink.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func routePicker(title: String, detail: String, selection: Binding<AIRoute>) -> some View {
    VStack(alignment: .leading, spacing: OmiSpacing.xs) {
      Text(title)
        .scaledFont(size: OmiType.body, weight: .medium)
        .foregroundColor(Ink.primary)
      Picker(title, selection: selection) {
        ForEach(AIRoute.allCases, id: \.self) { route in
          Text(route.displayName).tag(route)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      caption(detail)
    }
  }
}
