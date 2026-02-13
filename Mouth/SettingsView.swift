import SwiftUI

struct SettingsView: View {
    private enum SettingsTab: String, Hashable {
        case general
        case speech
        case hotkeys
        case updates
    }

    @ObservedObject var model: CodexSessionsViewModel
    let updater: UpdaterProviding

    @AppStorage(SaySpeech.providerDefaultsKey) private var speechProviderRaw: String = SaySpeech.Provider.macOS.rawValue
    @AppStorage(SaySpeech.elevenLabsVoiceDefaultsKey) private var elevenLabsVoiceID: String = ""
    @AppStorage(CodexVoiceAnnouncer.duckAudioIfPlayingDefaultsKey) private var duckAudioIfPlaying: Bool = true
    @AppStorage(CodexVoiceAnnouncer.summarizeWithPromptDefaultsKey) private var summarizeWithPromptEnabled: Bool = true
    @AppStorage(CodexVoiceAnnouncer.summarizePromptDefaultsKey) private var summarizePrompt: String = CodexVoiceAnnouncer.defaultSummarizePrompt
    @AppStorage(LaunchAtLoginManager.defaultsKey) private var launchAtLogin: Bool = false
    @AppStorage("mouth.auto_update_enabled") private var autoUpdateEnabled: Bool = true
    @AppStorage(StopSpeechHotkeyMode.defaultsKey) private var stopSpeechHotkeyModeRaw: String = StopSpeechHotkeyMode.mediaPlayPause.rawValue

    @State private var updaterStatusMessage: String = ""
    @State private var isCheckingForUpdates: Bool = false

    @State private var elevenLabsAPIKeyDraft: String = ""
    @State private var elevenLabsHasAPIKey: Bool = false
    @State private var elevenLabsKeyError: String?
    @State private var didLoadKey = false
    @State private var saveTask: Task<Void, Never>?
    @State private var testVoiceError: String?

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

    private var selectedProvider: SaySpeech.Provider {
        SaySpeech.Provider(rawValue: speechProviderRaw) ?? .macOS
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalPane
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            speechPane
                .tabItem { Label("Speech", systemImage: "waveform") }
                .tag(SettingsTab.speech)

            hotkeysPane
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(SettingsTab.hotkeys)

            updatesPane
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)
        }
        .padding(12)
        .frame(width: 460, height: 280, alignment: .topLeading)
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
        .onChange(of: elevenLabsAPIKeyDraft) { _, _ in
            persistElevenLabsAPIKeySoon()
        }
        .onChange(of: speechProviderRaw) { _, value in
            guard let provider = SaySpeech.Provider(rawValue: value) else {
                speechProviderRaw = SaySpeech.Provider.macOS.rawValue
                SaySpeech.setPreferredProvider(.macOS)
                return
            }
            SaySpeech.setPreferredProvider(provider)
        }
        .onChange(of: elevenLabsVoiceID) { _, value in
            SaySpeech.setPreferredElevenLabsVoiceID(value)
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
        .onChange(of: summarizeWithPromptEnabled) { _, enabled in
            guard enabled else { return }
            if summarizePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summarizePrompt = CodexVoiceAnnouncer.defaultSummarizePrompt
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

                Toggle("Duck audio if playing", isOn: $duckAudioIfPlaying)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var speechPane: some View {
        centeredTabContent {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Picker("Engine", selection: $speechProviderRaw) {
                        Text(SaySpeech.Provider.macOS.displayName).tag(SaySpeech.Provider.macOS.rawValue)
                        Text(SaySpeech.Provider.elevenLabs.displayName).tag(SaySpeech.Provider.elevenLabs.rawValue)
                    }

                    Button {
                        testVoice()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(testPlayback != nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)

                if selectedProvider == .elevenLabs {
                    ZStack(alignment: .trailing) {
                        SecureField("ElevenLabs API key", text: $elevenLabsAPIKeyDraft)
                            .textFieldStyle(.roundedBorder)

                        if elevenLabsHasAPIKey {
                            Button {
                                elevenLabsAPIKeyDraft = ""
                                persistElevenLabsAPIKeySoon()
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

                    TextField("Voice ID (optional)", text: $elevenLabsVoiceID)
                        .textFieldStyle(.roundedBorder)
                    Text("If empty, uses the first available ElevenLabs voice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let elevenLabsKeyError {
                        Text(elevenLabsKeyError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if let testVoiceError {
                    Text(testVoiceError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Toggle("Summarize with prompt", isOn: $summarizeWithPromptEnabled)
                    .toggleStyle(.checkbox)

                if summarizeWithPromptEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $summarizePrompt)
                            .font(.body)
                            .frame(minHeight: 68, maxHeight: 88)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
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

    private var hotkeysPane: some View {
        centeredTabContent {
            VStack(alignment: .leading, spacing: 10) {
                hotkeyRow(title: "Toggle Mouth enabled") {
                    KeyboardShortcuts.Recorder(for: .toggleMouthEnabled)
                }

                hotkeyRow(title: "Stop current speech") {
                    KeyboardShortcuts.Recorder(
                        for: .stopSpeech,
                        onChange: { shortcut in
                            let newValue = shortcut == nil
                                ? StopSpeechHotkeyMode.mediaPlayPause.rawValue
                                : StopSpeechHotkeyMode.keyboardShortcut.rawValue
                            if newValue != stopSpeechHotkeyModeRaw {
                                stopSpeechHotkeyModeRaw = newValue
                            }
                        },
                        placeholder: {
                            Image(systemName: "playpause.fill")
                                .font(.body.weight(.ultraLight))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }
                    )
                }
            }
        }
    }

    private func centeredTabContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: 330, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func hotkeyRow<Recorder: View>(title: String, @ViewBuilder recorder: () -> Recorder) -> some View {
        HStack {
            Text(title)
            Spacer()
            recorder()
        }
    }

    private func loadState() {
        didLoadKey = false
        elevenLabsKeyError = nil
        testVoiceError = nil

        speechProviderRaw = SaySpeech.preferredProvider().rawValue
        SaySpeech.setPreferredElevenLabsVoiceID(elevenLabsVoiceID)

        let key = (try? SaySpeech.loadElevenLabsAPIKey()) ?? ""
        elevenLabsAPIKeyDraft = key
        elevenLabsHasAPIKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        didLoadKey = true
    }

    private func persistElevenLabsAPIKeySoon() {
        guard didLoadKey else { return }

        saveTask?.cancel()

        let value = elevenLabsAPIKeyDraft
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }

            elevenLabsKeyError = nil
            do {
                try SaySpeech.setElevenLabsAPIKey(value)
                elevenLabsHasAPIKey = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } catch {
                elevenLabsKeyError = "Couldn't save API key."
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
        testVoiceError = nil

        // Force immediate provider/voice settings for this test press.
        SaySpeech.setPreferredProvider(selectedProvider)
        if selectedProvider == .elevenLabs {
            SaySpeech.setPreferredElevenLabsVoiceID(elevenLabsVoiceID)
        }

        let prompt = Self.testVoicePrompts.randomElement() ?? "Mouth speaking, how can I help?"
        do {
            let playback = try SaySpeech().play(prompt)
            testPlayback = playback
            try await playback.wait()
        } catch {
            testVoiceError = error.localizedDescription
        }
        testPlayback = nil
    }
}

#Preview {
    SettingsView(model: .init(engine: .init()), updater: DisabledUpdaterController())
}
