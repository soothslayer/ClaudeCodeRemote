import SwiftUI

/// Live tail of the server's output — the first place to look when the phone
/// can't reach the Mac.
struct ServerLogView: View {
    @EnvironmentObject private var controller: ServerController

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: controller.logLines.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }

            Divider()

            HStack {
                Text(controller.publicURL ?? "no tunnel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reveal Log Files") { controller.revealLogs() }
            }
            .padding(8)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
