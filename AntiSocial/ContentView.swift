import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pool: WebViewPool

    @State private var selection: String = TabGroup.messages.id
    /// Which page each two-page tab is showing (Alerts or My Posts).
    @State private var pageByGroup: [String: String] = [:]
    @State private var showSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(TabGroup.all) { group in
                TabPage(
                    group: group,
                    page: pageBinding(for: group),
                    controller: pool.controller(for: page(in: group)),
                    showSettings: $showSettings,
                    showDiagnostics: $showDiagnostics
                )
                .tabItem {
                    Label(group.title, systemImage: group.systemImage)
                }
                .tag(group.id)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(controller: pool.controller(for: currentPage), ownership: pool.ownership)
        }
    }

    private var currentGroup: TabGroup {
        TabGroup.all.first { $0.id == selection } ?? .messages
    }

    private var currentPage: WebTab {
        page(in: currentGroup)
    }

    private func page(in group: TabGroup) -> WebTab {
        let chosen = pageByGroup[group.id]
        return group.pages.first { $0.id == chosen } ?? group.pages[0]
    }

    private func pageBinding(for group: TabGroup) -> Binding<WebTab> {
        Binding(
            get: { page(in: group) },
            set: { pageByGroup[group.id] = $0.id }
        )
    }

    /// Tapping the tab you are already on jumps that page back to its home.
    /// Handy after you have drilled into a conversation or a listing.
    private var tabSelection: Binding<String> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == selection {
                    pool.controller(for: currentPage).goHome()
                } else {
                    selection = newValue
                }
            }
        )
    }
}

/// One tab: a slim bar on top, a switch when the tab holds more than one
/// page, and the guarded web view underneath.
struct TabPage: View {
    let group: TabGroup
    @Binding var page: WebTab
    @ObservedObject var controller: WebController
    @Binding var showSettings: Bool
    @Binding var showDiagnostics: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pool: WebViewPool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if group.pages.count > 1 {
                pagePicker
            }
            Divider()
            ZStack(alignment: .top) {
                // A new identity per page, so switching pages swaps in that
                // page's own web view instead of reusing the old one.
                GuardedWebView(controller: controller)
                    .id(page.id)
                    .ignoresSafeArea(edges: .bottom)

                if controller.isLoading {
                    ProgressView(value: min(max(controller.progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }

                if controller.isCheckingOwner {
                    checkingCard
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
                Text(group.title)
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
                    Label("Back to \(page.title)", systemImage: "house")
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

    /// Alerts or My Posts.
    private var pagePicker: some View {
        Picker("Show", selection: $page) {
            ForEach(group.pages) { item in
                Text(item.shortTitle).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .background(.bar)
    }

    /// Instagram has no web page for creating a Story or going live, and
    /// Marketplace is a Facebook thing, so the Instagram pages only offer a post.
    private var composeActions: [ComposeAction] {
        switch AccessPolicy.site(for: page.home) {
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

    /// Covers the page while the app checks that a post is yours. Someone
    /// else's post never shows, not even for a moment.
    private var checkingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Checking that this post is yours")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
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
