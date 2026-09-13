import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pool: WebViewPool

    @State private var selection: String = WebTab.facebookMessages.id
    @State private var showSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(WebTab.all) { tab in
                TabPage(
                    tab: tab,
                    controller: pool.controller(for: tab),
                    showSettings: $showSettings,
                    showDiagnostics: $showDiagnostics
                )
                .tabItem {
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .tag(tab.id)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(controller: pool.controller(for: currentTab))
        }
    }

    private var currentTab: WebTab {
        WebTab.all.first { $0.id == selection } ?? .facebookMessages
    }

    /// Tapping the tab you are already on jumps that tab back to its home
    /// page. Handy after you have drilled into a conversation or a listing.
    private var tabSelection: Binding<String> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == selection {
                    pool.controller(for: currentTab).goHome()
                } else {
                    selection = newValue
                }
            }
        )
    }
}

/// One tab: a slim bar on top, the guarded web view underneath.
struct TabPage: View {
    let tab: WebTab
    @ObservedObject var controller: WebController
    @Binding var showSettings: Bool
    @Binding var showDiagnostics: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pool: WebViewPool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ZStack(alignment: .top) {
                GuardedWebView(controller: controller)
                    .ignoresSafeArea(edges: .bottom)

                if controller.isLoading {
                    ProgressView(value: min(max(controller.progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }

                if let error = controller.loadError {
                    errorCard(error)
                }

                BlockToast(event: controller.lastBlock, enabled: settings.showBlockToasts)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                controller.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .disabled(!controller.canGoBack)
            .accessibilityLabel("Back")

            VStack(spacing: 1) {
                Text(tab.title)
                    .font(.subheadline.weight(.semibold))
                Text(hostLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .lineLimit(1)

            if settings.allowPosting {
                Menu {
                    ForEach(composeActions) { action in
                        Button {
                            controller.compose(action, ownInstagramUsername: pool.instagramUsername)
                        } label: {
                            Label(action.label, systemImage: action.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 32, height: 32)
                } primaryAction: {
                    controller.compose(.post, ownInstagramUsername: pool.instagramUsername)
                }
                .accessibilityLabel("Compose")
            }

            Button {
                controller.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Reload")

            Menu {
                Button {
                    controller.goHome()
                } label: {
                    Label("Back to \(tab.title)", systemImage: "house")
                }
                Button {
                    showDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(.bar)
    }

    /// Instagram has no web page for creating a Story or going live, and
    /// Marketplace is a Facebook thing, so the Instagram tabs only offer a post.
    private var composeActions: [ComposeAction] {
        switch AccessPolicy.site(for: tab.home) {
        case .instagram: return [.post]
        default: return ComposeAction.allCases
        }
    }

    private var hostLabel: String {
        guard let url = controller.currentURL, let host = url.host else {
            return " "
        }
        let path = url.path
        let trimmedHost = host.replacingOccurrences(of: "www.", with: "")
        if path.isEmpty || path == "/" {
            return trimmedHost
        }
        return trimmedHost + path
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Could not load the page")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") {
                controller.reload()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
