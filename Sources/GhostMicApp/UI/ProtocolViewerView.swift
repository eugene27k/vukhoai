import AppKit
import SwiftUI

struct ProtocolViewerView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let protocolPath: String

    @State private var rawMarkdown = ""
    @State private var renderedMarkdown: AttributedString?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                Button("Copy") {
                    copyCurrentText()
                }

                Button("Close", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Group {
                    if let renderedMarkdown {
                        Text(renderedMarkdown)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(rawMarkdown)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 600)
        .task {
            loadProtocol()
        }
        .alert("Protocol Error", isPresented: isShowingError) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadProtocol() {
        do {
            rawMarkdown = try String(contentsOfFile: protocolPath, encoding: .utf8)
            renderedMarkdown = try? AttributedString(markdown: rawMarkdown)
        } catch {
            errorMessage = "Unable to read protocol: \(error.localizedDescription)"
            rawMarkdown = ""
            renderedMarkdown = nil
        }
    }

    private func copyCurrentText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(rawMarkdown, forType: .string)
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in
                if !newValue {
                    errorMessage = nil
                }
            }
        )
    }
}
