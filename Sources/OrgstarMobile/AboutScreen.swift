#if os(iOS)
import SwiftUI
import UIKit

/// The version, and where to read the manual and source, report a problem or ask for help.
struct AboutScreen: View {
    /// The app icon in use, as `AppIcons` names it.
    let appIcon: String

    static let supportEmail = "help@krz.sh"

    private static let repository = "https://gitbay.org/krz/orgstar"

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return build == short ? short : "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    // Builds without the asset catalog have no preview.
                    if let icon = UIImage(named: "IconPreview-\(appIcon)") {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .accessibilityHidden(true)
                    }
                    Text("orgstar").font(.title2.bold())
                    Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                link("Manual", "book", "https://krz.gitbay.site/orgstar/")
                link("Release Notes", "sparkles", Self.repository + "/releases")
                link("Website", "globe", "https://krz.sh/apps/orgstar")
            }
            Section {
                link("Report an Issue", "ladybug", Self.repository + "/issues/new")
                link("Email Support", "envelope", mail.absoluteString)
                link("Rate on the App Store", "star", "https://apps.apple.com/app/id6821552018?action=write-review")
            } footer: {
                Text("Reporting an issue needs a gitbay account. Without one, email \(Self.supportEmail).")
            }
            Section {
                link("Source Code", "chevron.left.forwardslash.chevron.right", Self.repository)
                link("License", "doc.text", Self.repository + "/blob/main/LICENSE")
                link("Third-Party Notices", "doc.on.doc", Self.repository + "/blob/main/THIRD_PARTY.org")
                link("Privacy Policy", "hand.raised", "https://krz.sh/privacy/orgstar/")
            } footer: {
                Text("© 2026 Christian Cleberg. Free software under the 0BSD license.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A message to support with the version and device filled in.
    private var mail: URL {
        let device = UIDevice.current
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "orgstar \(version)"),
            URLQueryItem(name: "body", value: "\n\n—\norgstar \(version), \(device.systemName) \(device.systemVersion), \(device.model)"),
        ]
        return components.url!
    }

    private func link(_ title: LocalizedStringKey, _ systemImage: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Label(title, systemImage: systemImage)
        }
    }
}
#endif
