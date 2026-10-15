#if os(iOS)
import OrgPresentation
import SwiftUI
import UIKit

/// The app icons, as previews; tapping one makes it the home screen's icon.
struct AppIconScreen: View {
    /// The icon in use, shared with the Settings row.
    @Binding var current: String
    @State private var failure: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 16)], spacing: 20) {
                ForEach(AppIcons.ids, id: \.self) { id in
                    Button { choose(id) } label: {
                        VStack(spacing: 6) {
                            Image("IconPreview-\(id)")
                                .resizable()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(id == current ? Color.accentColor : .clear, lineWidth: 3).padding(-4))
                            Text(AppIcons.name(id)).font(.caption).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(id == current ? .isSelected : [])
                }
            }
            .padding()
            if let failure { Text(failure).foregroundStyle(.red).padding(.horizontal) }
        }
        .navigationTitle("App Icon")
    }

    private func choose(_ id: String) {
        guard id != current, UIApplication.shared.supportsAlternateIcons else { return }
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(AppIcons.alternateName(id))
                current = id
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
#endif
