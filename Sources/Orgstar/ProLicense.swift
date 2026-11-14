import OrgApp
import SwiftUI

/// Pro on the Mac: a license key bought from the website, or an install that predates Pro.
enum MacPro {
    static let buyURL = URL(string: "https://krz.sh/apps/orgstar/buy")!

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
                    LabeledContent("orgstar Pro", value: license.map { "Licensed to \($0.email)" } ?? "Licensed")
                case .grandfathered:
                    LabeledContent("orgstar Pro", value: "Included: you used orgstar before Pro")
                case .purchase, nil:
                    LabeledContent("orgstar Pro", value: "Not licensed")
                }
            }
            if access.grant != .license {
                Section {
                    TextField("License key", text: $key, prompt: Text("ORGSTAR1-…"), axis: .vertical)
                        .lineLimit(2...4)
                        .font(.body.monospaced())
                        .onSubmit(activate)
                    if let error { Text(error).foregroundStyle(.red) }
                    HStack {
                        Link("Buy orgstar Pro…", destination: MacPro.buyURL)
                        Spacer()
                        Button("Activate", action: activate).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    Text("Your key is in the email from the purchase. It is checked on this Mac; nothing is sent.")
                }
            } else {
                Section {
                    Button("Remove License from This Mac", role: .destructive) {
                        LicenseStore.remove()
                        license = nil
                        MacPro.resolve()
                    }
                }
            }
            Section("Included in Pro") {
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
            error = "This key isn't valid for orgstar. Paste the whole key from the email."
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
                Label("\(feature.title) needs orgstar Pro", systemImage: feature.systemImage).font(.headline)
                Text("Pro is a one-time purchase of $39.99 for this Mac. Editing, the agenda, capture, clocking and search stay free.")
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

extension ProFeature {
    /// The Pro features the Mac app has.
    static let macFeatures: [ProFeature] = [.babel, .export, .encryption, .roam, .widgets, .calendar, .shortcuts]
}
