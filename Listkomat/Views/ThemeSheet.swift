import SwiftUI

/// Picker for the top-bar theme. Tapping a row applies it live (the bar behind
/// the sheet recolors immediately) and there's no Save button — just "Hotovo".
struct ThemeSheet: View {
    @Binding var themeId: String
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Režim") {
                    Picker("Režim", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Motiv") {
                    ForEach(AppTheme.presets) { theme in
                        Button {
                            themeId = theme.id
                            dismiss()
                        } label: { row(theme) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Vzhled")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hotovo") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ theme: AppTheme) -> some View {
        HStack(spacing: 14) {
            // Miniature of the bar: band color with its mascot / contrast hint.
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(theme.band ?? Color(.systemBackground))
                if let mascot = theme.mascot {
                    Text(mascot).font(.system(size: 18))
                } else {
                    // Clean / Černá: preview the accent color with "Aa".
                    Text("Aa").font(.caption.bold()).foregroundStyle(theme.accent)
                }
            }
            .frame(width: 56, height: 34)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            Text(theme.name)
                .font(.brandBold(17, relativeTo: .body))
                .foregroundStyle(.primary)

            Spacer()

            if theme.id == themeId {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.resolve(themeId).accent)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}
