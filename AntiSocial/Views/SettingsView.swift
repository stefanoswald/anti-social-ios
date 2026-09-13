import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pool: WebViewPool
    @Environment(\.dismiss) private var dismiss

    @State private var confirmLogout = false
    @State private var isClearing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Facebook username", text: $settings.facebookUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Instagram username", text: $settings.instagramUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Your accounts")
                } footer: {
                    Text("The app fills these in by itself once you have used each tab. They let you open your own profile and post there. Every other profile stays blocked.")
                }

                Section {
                    Toggle("Allow posting", isOn: $settings.allowPosting)
                } header: {
                    Text("Posting")
                } footer: {
                    Text("Turns on the compose button: write a post, add a story, go live, or list something on Marketplace. Watching other people's Reels and Stories stays blocked either way.")
                }

                Section {
                    Toggle("Hide feed links inside pages", isOn: $settings.hideDistractions)
                    Toggle("Allow single Reels from notifications", isOn: $settings.allowReelPermalinks)
                    Toggle("Allow single group posts", isOn: $settings.allowGroupPosts)
                    Picker("Links that leave Facebook or Instagram", selection: $settings.externalLinks) {
                        ForEach(AppSettings.ExternalLinkBehavior.allCases) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    Toggle("Show a banner when something is blocked", isOn: $settings.showBlockToasts)
                } header: {
                    Text("Blocking")
                } footer: {
                    Text("Feeds, Reels, Watch, Stories, Explore, and other people's profiles are always blocked. These switches only fine-tune the edges.")
                }

                Section {
                    Toggle("Desktop site for Facebook", isOn: $settings.desktopModeFacebook)
                    Toggle("Desktop site for Instagram", isOn: $settings.desktopModeInstagram)
                    Picker("Desktop page width", selection: $settings.desktopViewportWidth) {
                        ForEach(AppSettings.desktopViewportChoices, id: \.self) { width in
                            Text(Self.widthLabel(width)).tag(width)
                        }
                    }
                } header: {
                    Text("Site mode")
                } footer: {
                    Text("Facebook's mobile site refuses to show Messenger, so Facebook uses the desktop site. Page width controls how much the desktop layout is shrunk to fit the phone. Narrower means bigger text. You can also pinch to zoom.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        if isClearing {
                            ProgressView()
                        } else {
                            Text("Log out of everything")
                        }
                    }
                    .disabled(isClearing)
                } footer: {
                    Text("Clears all cookies and site data. You will need to sign in again.")
                }

                Section("About") {
                    LabeledContent("Version", value: Self.versionString)
                    Text("Anti-Social loads only the inbox, Marketplace, and notification pages. Everything else is stopped before it loads, so there is nothing to scroll.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Log out of Facebook and Instagram?",
                isPresented: $confirmLogout,
                titleVisibility: .visible
            ) {
                Button("Log out", role: .destructive) {
                    Task {
                        isClearing = true
                        await pool.clearWebsiteData()
                        isClearing = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private static func widthLabel(_ width: Int) -> String {
        switch width {
        case 600: return "Narrow (600)"
        case 680: return "Compact (680)"
        case 760: return "Balanced (760)"
        case 840: return "Roomy (840)"
        case 980: return "Full desktop (980)"
        default: return "\(width)"
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
