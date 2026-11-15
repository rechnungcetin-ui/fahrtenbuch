import SwiftUI
import UIKit
import Vision
import VisionKit

struct ReceiptData {
    var amount: Double?
    var quantity: Double?
    var date: Date?
    var vendor: String?
}

/// Liest Betrag, Liter, Datum und Anbieter per Texterkennung vom Beleg (läuft komplett auf dem iPhone).
enum ReceiptReader {
    static func read(_ image: UIImage) async -> ReceiptData {
        guard let cgImage = image.cgImage else { return ReceiptData() }
        let lines: [String] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["de-DE", "en-US"]
                request.usesLanguageCorrection = false
                try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
        }
        return parse(lines)
    }

    static func parse(_ lines: [String]) -> ReceiptData {
        var data = ReceiptData()
        let text = lines.joined(separator: "\n")

        data.vendor = lines.first { $0.count > 2 && $0.rangeOfCharacter(from: .letters) != nil }

        // Betrag: bevorzugt aus Zeilen mit „Summe / Gesamt / Total“, sonst der größte Euro-Betrag.
        let money = "(\\d{1,4}[.,]\\d{2})(?!\\d)"
        let keywords = ["summe", "gesamt", "total", "betrag", "zu zahlen", "endbetrag", "brutto"]
        let keywordLines = lines.filter { line in keywords.contains { line.lowercased().contains($0) } }
        var candidates = keywordLines.flatMap { groups(money, in: $0).compactMap { Fmt.parseDecimal($0[1]) } }
        if candidates.isEmpty {
            candidates = groups(money + "\\s*(€|eur)", in: text).compactMap { Fmt.parseDecimal($0[1]) }
        }
        if candidates.isEmpty {
            candidates = groups(money, in: text).compactMap { Fmt.parseDecimal($0[1]) }
        }
        data.amount = candidates.filter { $0 > 0 && $0 < 5000 }.max()

        // Menge: „45,67 l“ / „45,67 Liter“ / „32,10 kWh“
        if let match = groups("(\\d{1,3}[.,]\\d{1,3})\\s*(l|ltr|liter|kwh)\\b", in: text).first {
            data.quantity = Fmt.parseDecimal(match[1])
        }

        // Datum: 15.11.2026 oder 15.11.26
        if let match = groups("\\b(\\d{2})\\.(\\d{2})\\.(\\d{4}|\\d{2})\\b", in: text).first,
           let day = Int(match[1]), let month = Int(match[2]), var year = Int(match[3]) {
            if year < 100 { year += 2000 }
            if let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
               date <= Date.now.addingTimeInterval(86_400) {
                data.date = date
            }
        }
        return data
    }

    private static func groups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map {
                match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0))
            }
        }
    }
}

extension UIImage {
    /// Verkleinert das Bild (spart Speicher und iCloud-Platz) und richtet es korrekt aus.
    func resized(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Apples Dokumentenscanner (erkennt Kanten, begradigt den Beleg).
struct DocumentScanner: UIViewControllerRepresentable {
    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    let onScan: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            if scan.pageCount > 0 { parent.onScan(scan.imageOfPage(at: 0)) }
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}
