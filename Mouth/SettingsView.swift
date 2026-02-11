import SwiftUI

struct SettingsView: View {
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
        Form {
            if !updaterStatusMessage.isEmpty {
                Text(updaterStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            } else if let reason = updater.unavailableReason, !reason.isEmpty {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }

            Toggle("Start at login", isOn: $launchAtLogin)
                .padding(.bottom, 12)

            Toggle("Mouth enabled", isOn: enabledBinding)
                .padding(.bottom, 12)

            Toggle("Pause music while speaking", isOn: $pauseExternalPlaybackWhileSpeaking)
                .padding(.bottom, 12)

            HStack {
                Picker("Voice engine", selection: $speechProviderRaw) {
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
                .help("Test voice")
                .disabled(testPlayback != nil)
            }
            .padding(.bottom, 12)

            if sagInstalled, selectedProvider == .sag {
                ZStack(alignment: .trailing) {
                    SecureField("ElevenLabs API key", text: $sagAPIKeyDraft)
                        .padding(.leading, 12)

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
                        .padding(.horizontal, 6)
                        .background()
                    }
                }

                if let sagKeyError {
                    Text(sagKeyError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Toggle("Check for updates automatically", isOn: $autoUpdateEnabled)
                .disabled(!updater.isAvailable)
                .padding(.bottom, 12)

            Button(isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…") {
                Task { @MainActor in
                    updater.checkForUpdates(nil)
                }
            }
            .disabled(!updater.isAvailable || isCheckingForUpdates)
        }
        .padding(20)
        .onAppear {
            loadState()
            Task { @MainActor in
                updater.automaticallyChecksForUpdates = autoUpdateEnabled
                updater.automaticallyDownloadsUpdates = autoUpdateEnabled
            }
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

    private func loadState() {
        // If SAG was previously selected but is no longer installed, reset to macOS say.
        if !sagInstalled, selectedProvider == .sag {
            speechProviderRaw = SaySpeech.Provider.macOSSay.rawValue
        }

        // Apply launch-at-login in case the user opened Settings before app startup finished,
        // or if a previous register/unregister failed transiently.
        LaunchAtLoginManager.setEnabled(launchAtLogin)

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
        Task { @MainActor in
            // Cancel any in-flight test.
            testPlayback?.cancel()
            testPlayback = nil

            do {
                let prompts = [
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
                let p = try SaySpeech().play(prompts.randomElement()!)
                testPlayback = p
                try await p.wait()
            } catch {
                // Keep UI quiet; this is a best-effort test.
            }
            testPlayback = nil
        }
    }
}

#Preview {
    SettingsView(model: .init(engine: .init()), updater: DisabledUpdaterController())
}
