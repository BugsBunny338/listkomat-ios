import SwiftUI

/// Friendly priming screen shown before the system location prompt, so the user
/// understands why we ask. Per App Store Guideline 5.1.1(iv), it always proceeds
/// to the system permission request — no neutral wording, no escape button.
struct LocationPrimerView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.brandTeal)

            Text("Najít nejbližší město")
                .font(.brandBold(22, relativeTo: .title2))

            Text("S přístupem k poloze vám Lístkomat rovnou nabídne lístky pro město, ve kterém právě jste. Polohu nikam neodesíláme. Pokud přístup nepovolíte, můžete si město kdykoli vybrat ručně.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onContinue) {
                Text("Pokračovat")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
