import SwiftUI

/// Friendly priming screen shown before the system location prompt, so the user
/// understands why we ask (and can opt to choose a city manually instead).
struct LocationPrimerView: View {
    let onAllow: () -> Void
    let onManual: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.brandTeal)

            Text("Najít nejbližší město")
                .font(.brandBold(22, relativeTo: .title2))

            Text("S přístupem k poloze vám Lístkomat rovnou nabídne lístky pro město, ve kterém právě jste. Polohu nikam neodesíláme.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button(action: onAllow) {
                    Text("Povolit přístup k poloze")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onManual) {
                    Text("Teď ne, vyberu město sám")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
