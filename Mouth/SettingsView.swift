import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: CodexSessionsViewModel
    @AppStorage(SaySpeech.providerDefaultsKey) private var speechProviderRaw: String = SaySpeech.Provider.macOSSay.rawValue

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
            Toggle("Mouth enabled", isOn: enabledBinding)
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
                        .padding(.trailing, 6)
                    }
                }

                if let sagKeyError {
                    Text(sagKeyError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

        }
        .padding(20)
        .onAppear { loadState() }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
        }
        .onChange(of: sagAPIKeyDraft) { _, _ in
            persistSAGAPIKeySoon()
        }
    }

    private func loadState() {
        // If SAG was previously selected but is no longer installed, reset to macOS say.
        if !sagInstalled, selectedProvider == .sag {
            speechProviderRaw = SaySpeech.Provider.macOSSay.rawValue
        }

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
                let p = try SaySpeech().play("Hi, I am Mouth")
                testPlayback = p
                try await p.wait()
            } catch {
                // Keep UI quiet; this is a best-effort test.
            }
            testPlayback = nil
        }
    }
}
