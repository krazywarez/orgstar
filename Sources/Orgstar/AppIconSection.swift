import AppKit
import OrgPresentation
import SwiftUI

/// Settings ▸ Appearance ▸ App Icon: the icon the Dock shows while orgstar runs.
struct AppIconSection: View {
    @AppStorage("appIcon") private var appIcon = "default"

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                ForEach(AppIcons.ids, id: \.self) { id in
                    Button {
                        appIcon = id
                        DockIcon.apply()
                    } label: {
                        VStack(spacing: 4) {
                            preview(id)
                                .resizable()
                                .frame(width: 56, height: 56)
                                .padding(4)
                                .background(id == appIcon ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            Text(AppIcons.name(id)).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(id == appIcon ? .isSelected : [])
                }
            }
        } header: {
            Text("App Icon")
        } footer: {
            Text("The icon shows in the Dock while orgstar runs. Finder, and the Dock after orgstar quits, show the default icon.")
                .settingsFooter()
        }
    }

    private func preview(_ id: String) -> Image {
        let url = Bundle.main.url(forResource: "\(id)-light", withExtension: "png", subdirectory: "IconPreviews")
        return url.flatMap { NSImage(contentsOf: $0) }.map { Image(nsImage: $0) } ?? Image(nsImage: NSApp.applicationIconImage)
    }
}
