import OrgApp
import SwiftUI

#if !APPSTORE
/// Pro on the Mac: a license key for sponsoring on GitHub, or an install that predates Pro.
enum MacPro {
    static let buyURL = URL(string: "https://krz.sh/apps/orgstar/buy")!
    static let keyURL = URL(string: "https://krz.sh/apps/orgstar/license")!

    /// Sets `ProAccess.shared` from the stored license or an earlier free install.
    @MainActor static func resolve() {
        if LicenseStore.current() != nil {
            ProAccess.shared.set(.license)
        } else if Grandfathering.macPredatesPro(marker: WorkspaceModel.defaultDirectory.appendingPathComponent("roots.json")) {
            ProAccess.shared.set(.grandfathered)
        } else {
            ProAccess.shared.set(nil)
        }
    }

    /// Renews a monthly sponsor's key now and then daily, and re-resolves, so an ended
    /// sponsorship locks orgstar+ once its key expires.
    @MainActor static func renewInBackground() {
        Task {
            while true {
                _ = await LicenseStore.renewIfDue()
                resolve()
                try? await Task.sleep(for: .seconds(86400))
            }
        }
    }
}

/// Status, buying, and entering or removing a license key.
struct LicenseForm: View {
    @State private var key = ""
    @State private var error: String?
    @State private var license = LicenseStore.current()
    private var access: ProAccess { ProAccess.shared }

    var body: some View {
        Form {
            Section {
                switch access.grant {
                case .license:
                    LabeledContent("orgstar+", value: license.map { "Licensed to \($0.holder)" } ?? "Licensed")
                    if let expires = license?.expires {
                        let date = Date(timeIntervalSince1970: TimeInterval(expires)).formatted(date: .abbreviated, time: .omitted)
                        Text("Renews while you sponsor monthly. This key is valid until \(date).", tableName: "DeveloperID")
                            .foregroundStyle(.secondary)
                    }
                case .grandfathered:
                    LabeledContent("orgstar+", value: "Included: you used orgstar before orgstar+")
                case .purchase, nil:
                    LabeledContent("orgstar+", value: "Not licensed")
                }
            }
            if access.grant != .license {
                Section {
                    TextField(text: $key, prompt: Text("ORGSTAR1-…", tableName: "DeveloperID"), axis: .vertical) { Text("License key", tableName: "DeveloperID") }
                        .lineLimit(2...4)
                        .font(.body.monospaced())
                        .onSubmit(activate)
                    if let error { Text(error).foregroundStyle(.red) }
                    HStack {
                        Link(destination: MacPro.buyURL) { Text("Sponsor for orgstar+…", tableName: "DeveloperID") }
                        Link(destination: MacPro.keyURL) { Text("Get Your Key…", tableName: "DeveloperID") }
                        Spacer()
                        Button(action: activate) { Text("Activate", tableName: "DeveloperID") }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    Text("Sponsors get their key by signing in with GitHub. It is checked on this Mac; a monthly sponsor's key is renewed with krz.sh.", tableName: "DeveloperID")
                }
            } else {
                Section {
                    Button(role: .destructive) {
                        LicenseStore.remove()
                        license = nil
                        MacPro.resolve()
                    } label: {
                        Text("Remove License from This Mac", tableName: "DeveloperID")
                    }
                }
            }
            Section("Included in orgstar+") {
                ForEach(ProFeature.macFeatures) { feature in
                    Label(feature.title, systemImage: feature.systemImage)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func activate() {
        do {
            license = try LicenseStore.activate(key)
            key = ""
            error = nil
            ProAccess.shared.set(.license)
        } catch .badSignature {
            error = "This key isn't valid for orgstar. Paste the whole key from the license page."
        } catch .expired {
            error = "This key has expired. Sign in on the license page for a current one."
        } catch {
            self.error = "That doesn't look like an orgstar license key."
        }
    }
}

/// Shown when a Pro feature is used without Pro.
struct ProPaywallSheet: View {
    let feature: ProFeature
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(feature.title) needs orgstar+", systemImage: feature.systemImage).font(.headline)
                Text("orgstar+ for Mac comes with sponsoring orgstar on GitHub: $60 once, or $5 a month. Editing, the agenda, capture, clocking and search stay free.", tableName: "DeveloperID")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            LicenseForm()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480, height: 520)
        .onChange(of: ProAccess.shared.isUnlocked) { _, unlocked in if unlocked { dismiss() } }
    }
}

#endif

extension ProFeature {
    /// The Pro features the Mac app has.
    static let macFeatures: [ProFeature] = [.babel, .export, .encryption, .roam, .widgets, .calendar, .shortcuts]
}
