import SwiftUI
import MessageUI

/// Wraps MFMessageComposeViewController. iOS never auto-sends — the user taps
/// Send. The `.sent` result is what will trigger the time-left Live Activity (M3).
struct MessageComposeView: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    var onResult: (MessageComposeResult) -> Void

    static var canSendText: Bool { MFMessageComposeViewController.canSendText() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = [recipient]
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onResult: (MessageComposeResult) -> Void
        init(onResult: @escaping (MessageComposeResult) -> Void) { self.onResult = onResult }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onResult(result)
            controller.dismiss(animated: true)
        }
    }
}
