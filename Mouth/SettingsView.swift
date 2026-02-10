import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: CodexSessionsViewModel

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { !model.isPaused },
            set: { enabled in
                model.setPaused(!enabled)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Mouth enabled", isOn: enabledBinding)
            } footer: {
                Text("When disabled, Mouth stops monitoring Codex sessions and won't speak new messages.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 360)
        .padding(20)
    }
}

