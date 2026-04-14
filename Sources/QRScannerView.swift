import SwiftUI
import VisionKit

// MARK: - QRScannerView
// Wraps DataScannerViewController to scan a QR code containing the server URL.
// Calls onScanned(_ url: String) as soon as a valid http(s) URL is detected,
// then the caller is responsible for dismissing the sheet.

struct QRScannerView: UIViewControllerRepresentable {

    let onScanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScanned: onScanned)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    // MARK: - Coordinator

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScanned: (String) -> Void
        private var didFire = false   // Only fire once per scan session

        init(onScanned: @escaping (String) -> Void) {
            self.onScanned = onScanned
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didFire else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue,
                   payload.lowercased().hasPrefix("http") {
                    didFire = true
                    dataScanner.stopScanning()
                    onScanned(payload)
                    return
                }
            }
        }
    }
}
