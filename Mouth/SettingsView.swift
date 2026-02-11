import SwiftUI

struct SettingsView: View {
    private enum SettingsTab: String, Hashable {
        case general
        case speech
        case updates
    }

    @ObservedObject var model: CodexSessionsViewModel
    let updater: UpdaterProviding

    @AppStorage(SaySpeech.providerDefaultsKey) private var speechProviderRaw: String = SaySpeech.Provider.macOSSay.rawValue
    @AppStorage(CodexVoiceAnnouncer.pauseExternalPlaybackDefaultsKey) private var pauseExternalPlaybackWhileSpeaking: Bool = true
    @AppStorage(LaunchAtLoginManager.defaultsKey) private var launchAtLogin: Bool = false
    @AppStorage("mouth.auto_update_enabled") private var autoUpdateEnabled: Bool = true

    @State private var updaterStatusMessage: String = ""
    @State private var isCheckingForUpdates: Bool = false

    @State private var sagAPIKeyDraft: String = ""
    @State private var sagHasAPIKey: Bool = false
    @State private var sagKeyError: String?
    @State private var didLoadKey = false
    @State private var saveTask: Task<Void, Never>?

    @State private var testPlayback: SaySpeech.Playback?
    @State private var selectedTab: SettingsTab = .general

    private static let testVoicePrompts: [String] = [
        "Mouth speaking, how can I help?",
        "It's me, Mouth. What do you want?",
        "Mouth here, unfortunately.",
        "The one and only Mouth, at your service.",
        "Mouth's in the house, what's your issue?",
        "Hi, I'm Mouth. Don't ask how I'm doing.",
        "Mouth speaking. Please be patient.",
        "You've reached Mouth. This better be good.",
        "It's just Mouth. No, I can't fix your WiFi.",
        "Mouth here, ready to disappoint you.",
    ]

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { !model.isPaused },
            set: { enabled in
                model.setPaused(!enabled)
            }
        )
    }

    private var sagInstalled: Bool {
        SaySpeech.isSAGInstalled()
    }

    private var selectedProvider: SaySpeech.Provider {
        SaySpeech.Provider(rawValue: speechProviderRaw) ?? .macOSSay
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalPane
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            speechPane
                .tabItem { Label("Speech", systemImage: "waveform") }
                .tag(SettingsTab.speech)

            updatesPane
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)
        }
        .padding(12)
        .frame(width: 430, height: 240, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            loadState()
            updater.automaticallyChecksForUpdates = autoUpdateEnabled
            updater.automaticallyDownloadsUpdates = autoUpdateEnabled
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .mouthUpdaterStatusChanged)) { note in
            guard let statusRaw = note.userInfo?["status"] as? String,
                  let status = MouthUpdaterStatus(rawValue: statusRaw) else { return }

            let message = (note.userInfo?["message"] as? String) ?? ""
            updaterStatusMessage = message

            switch status {
            case .checking:
                isCheckingForUpdates = true
            default:
                isCheckingForUpdates = false
            }
        }
        .onChange(of: sagAPIKeyDraft) { _, _ in
            persistSAGAPIKeySoon()
        }
        .onChange(of: launchAtLogin) { _, enabled in
            LaunchAtLoginManager.setEnabled(enabled)
        }
        .onChange(of: autoUpdateEnabled) { _, enabled in
            Task { @MainActor in
                updater.automaticallyChecksForUpdates = enabled
                updater.automaticallyDownloadsUpdates = enabled
            }
        }
    }

    private var generalPane: some View {
        centeredTabContent {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Mouth enabled", isOn: enabledBinding)
                    .toggleStyle(.checkbox)

                Toggle("Start at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)

                Toggle("Pause music while speaking", isOn: $pauseExternalPlaybackWhileSpeaking)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var speechPane: some View {
        centeredTabContent {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Picker("Engine", selection: $speechProviderRaw) {
                        Text(SaySpeech.Provider.macOSSay.displayName).tag(SaySpeech.Provider.macOSSay.rawValue)
                        Text(SaySpeech.Provider.sag.displayName)
                            .tag(SaySpeech.Provider.sag.rawValue)
                            .disabled(!sagInstalled)
                    }

                    Button {
                        testVoice()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(testPlayback != nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if sagInstalled, selectedProvider == .sag {
                    ZStack(alignment: .trailing) {
                        SecureField("ElevenLabs API key", text: $sagAPIKeyDraft)
                            .textFieldStyle(.roundedBorder)

                        if sagHasAPIKey {
                            Button {
                                sagAPIKeyDraft = ""
                                persistSAGAPIKeySoon()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear API key")
                            .padding(.trailing, 8)
                            .padding(.horizontal, 12)
                            .background()
                        }
                    }

                    if let sagKeyError {
                        Text(sagKeyError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var updatesPane: some View {
        centeredTabContent {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Check for updates automatically", isOn: $autoUpdateEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(!updater.isAvailable)

                Button(isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…") {
                    updater.checkForUpdates(nil)
                }
                .disabled(!updater.isAvailable || isCheckingForUpdates)

                if !updaterStatusMessage.isEmpty {
                    Text(updaterStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let reason = updater.unavailableReason, !reason.isEmpty {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func centeredTabContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: 330, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func loadState() {
        didLoadKey = false
        sagKeyError = nil

        let key = (try? SaySpeech.loadSAGAPIKey()) ?? ""
        sagAPIKeyDraft = key
        sagHasAPIKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        didLoadKey = true
    }

    private func persistSAGAPIKeySoon() {
        guard didLoadKey else { return }

        saveTask?.cancel()

        // Debounce to avoid hammering Keychain on each keystroke.
        let value = sagAPIKeyDraft
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }

            sagKeyError = nil
            do {
                try SaySpeech.setSAGAPIKey(value)
                sagHasAPIKey = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } catch {
                sagKeyError = "Couldn't save API key."
            }
        }
    }

    private func testVoice() {
        Task {
            await performVoiceTest()
        }
    }

    private func performVoiceTest() async {
        // Cancel any in-flight test.
        testPlayback?.cancel()
        testPlayback = nil

        let prompt = Self.testVoicePrompts.randomElement() ?? "Mouth speaking, how can I help?"
        do {
            let playback = try SaySpeech().play(prompt)
            testPlayback = playback
            try await playback.wait()
        } catch {
            // Keep UI quiet; this is a best-effort test.
        }
        testPlayback = nil
    }
}

#Preview {
    SettingsView(model: .init(engine: .init()), updater: DisabledUpdaterController())
}
