import SwiftUI
import UIKit

/// Tools for when something slips through or gets blocked that should not be.
/// Copy the page map or the block log and send it over, and the rules can be
/// tightened without guessing.
struct DiagnosticsView: View {
    @ObservedObject var controller: WebController
    @EnvironmentObject private var pool: WebViewPool
    @Environment(\.dismiss) private var dismiss

    @State private var pageMap: String = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("Current page") {
                    LabeledContent("Tab", value: controller.tab.title)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(controller.currentURL?.absoluteString ?? "none")
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    Button {
                        Task { await capturePageMap() }
                    } label: {
                        Label("Capture page map", systemImage: "doc.text.magnifyingglass")
                    }
                    if !pageMap.isEmpty {
                        Button {
                            UIPasteboard.general.string = pageMap
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy page map", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        ShareLink(item: pageMap) {
                            Label("Share page map", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section {
                    if pool.blockLog.isEmpty {
                        Text("Nothing blocked yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(pool.blockLog) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(event.reason)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(event.date, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.tabTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(event.url.absoluteString)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Block log")
                } footer: {
                    if !pool.blockLog.isEmpty {
                        HStack {
                            ShareLink(item: blockLogText) {
                                Label("Share log", systemImage: "square.and.arrow.up")
                            }
                            Spacer()
                            Button("Clear log") {
                                pool.clearBlockLog()
                            }
                        }
                        .font(.footnote)
                        .padding(.top, 4)
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var blockLogText: String {
        let formatter = ISO8601DateFormatter()
        return pool.blockLog
            .map { "\(formatter.string(from: $0.date))\t\($0.tabTitle)\t\($0.reason)\t\($0.url.absoluteString)" }
            .joined(separator: "\n")
    }

    private func capturePageMap() async {
        copied = false
        pageMap = await controller.pageMap()
    }
}
