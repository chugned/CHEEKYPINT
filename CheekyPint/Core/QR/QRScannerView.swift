import SwiftUI
import VisionKit

/// A QR scanner built on VisionKit's `DataScannerViewController` (master prompt §4). It reports
/// the first QR payload string it sees; the caller resolves it through the backend. Includes a
/// clear availability fallback so the manual friend-code path can take over (§22).
struct QRScannerView: UIViewControllerRepresentable {
    /// Called with a scanned payload string. The caller stops scanning by dismissing.
    let onScan: (String) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        try? scanner.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle([item])
        }

        private func handle(_ items: [RecognizedItem]) {
            guard !hasScanned else { return }
            for case let .barcode(barcode) in items {
                if let payload = barcode.payloadStringValue {
                    hasScanned = true
                    onScan(payload)
                    return
                }
            }
        }
    }
}
