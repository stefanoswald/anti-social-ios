import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pool: WebViewPool
    @Environment(\.dismiss) private var dismiss

    @State private var confirmLogout = false
    @State private var isClearing = false
    /// The username boxes edit these, and they are saved when you finish
    /// (Return, or closing Settings). Saving on every keystroke would point
    /// the app at half-typed names, which are other people's accounts.
    @State private var facebookName = ""
    @State private var instagramName = ""
    /// What the boxes showed when Settings opened. Only a name you changed is
    /// saved, so a name the app learns meanwhile is not overwritten.
    @State private var shownFacebookName = ""
    @State private var shownInstagramName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Facebook username", text: $facebookName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveNames)
                    TextField("Instagram username", text: $instagramName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveNames)
                } header: {
                    Text("Your accounts")
                } footer: {
                    Text("The app fills these in by itself once you have used each tab. They tell the app which profile and which posts are yours.")
                }

                Section {
                    Toggle("Open posts and profiles I tap", isOn: $settings.openTappedPosts)
                } header: {
                    Text("Posts")
                } footer: {
                    Text("Your own posts, Reels, videos, and stories always open. With this on, a post or profile you tap opens too, so you can read it, reply, and see who someone is. Videos play one at a time. Other people's profiles and videos stop after a short scroll. Swiping or autoplay into the next post is blocked. Turn this off to open only your own posts.")
                }

                Section {
                    Toggle("Allow posting", isOn: $settings.allowPosting)
                } header: {
                    Text("Posting")
                } footer: {
                    Text("Turns on the compose button, so you can write a post, add a story, go live, or sell something on Marketplace.")
                }

                Section {
                    Toggle("Hide feed links inside pages", isOn: $settings.hideDistractions)
                    Picker("Links that leave Facebook or Instagram", selection: $settings.externalLinks) {
                        ForEach(AppSettings.ExternalLinkBehavior.allCases) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    Toggle("Show a banner when something is blocked", isOn: $settings.showBlockToasts)
                } header: {
                    Text("Blocking")
                } footer: {
                    Text("The home feed, the Reels and Watch feeds, the Stories feed, Explore, and the Groups feed are always blocked. Your groups stay open.")
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
                    Text("Anti-Social is for making, not scrolling. Messages, Marketplace, alerts, groups, your own posts, and posting all work. Feeds are stopped before they load, and nothing moves on to the next post by itself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveNames()
                        dismiss()
                    }
                }
            }
            .onAppear {
                facebookName = settings.facebookUsername
                instagramName = settings.instagramUsername
                shownFacebookName = facebookName
                shownInstagramName = instagramName
            }
            .onDisappear(perform: saveNames)
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

    private func saveNames() {
        let facebook = facebookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let instagram = instagramName.trimmingCharacters(in: .whitespacesAndNewlines)
        if facebookName != shownFacebookName, facebook != settings.facebookUsername {
            settings.facebookUsername = facebook
            shownFacebookName = facebookName
        }
        if instagramName != shownInstagramName, instagram != settings.instagramUsername {
            settings.instagramUsername = instagram
            shownInstagramName = instagramName
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
