//

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CodexSessionsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Active Codex Sessions")
                    .font(.title2)
                Text("\(model.sessions.count)")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if model.sessions.isEmpty {
                Text("No active Codex sessions detected.")
                    .foregroundStyle(.secondary)
            } else {
                List(model.sessions) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(s.sessionID ?? "(unparsed session id)")
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text("pids: \(s.pids.map(String.init).joined(separator: ", "))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Text(s.fileURL.path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([s.fileURL])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                        }

                        if let text = s.latestAssistantText, !text.isEmpty {
                            Text(text)
                                .font(.callout)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        } else {
                            Text("(no assistant message found yet)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            if let d = s.fileModificationDate {
                                Text("mtime: \(d.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let d = s.lastChangeAt {
                                Text("changed: \(d.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let n = s.fileSizeBytes {
                                Text("size: \(n)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let d = s.latestAssistantAt {
                                Text("ai: \(d.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
    }
}

#Preview {
    ContentView(model: CodexSessionsViewModel())
}
