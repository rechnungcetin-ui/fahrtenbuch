import UIKit

struct ExportPeriod {
    let year: Int
    let month: Int?

    var title: String { month.map { "\(Fmt.monthName($0)) \(year)" } ?? "Kalenderjahr \(year)" }
    var fileStem: String { month.map { String(format: "%04d-%02d", year, $0) } ?? String(year) }

    /// Letzter Tag des Zeitraums (Belegdatum für den Fahrtgeld-Eigenbeleg).
    var lastDay: Date {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: year, month: month ?? 12, day: 1)) ?? .now
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return calendar.date(byAdding: .day, value: -1, to: next) ?? start
    }

    func contains(_ date: Date) -> Bool {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return c.year == year && (month == nil || c.month == month)
    }
}

/// Erstellt das Fahrtenbuch als PDF (zum Ausdrucken / Weitergeben) und CSV (für Excel / Buchhaltung).
@MainActor
enum ExportService {
    // MARK: - Felder

    private static func fields(_ t: Trip) -> (start: String, end: String, purpose: String) {
        switch t.category {
        case .privateTrip:
            return ("–", "–", "Privatfahrt")
        case .commute:
            return (t.startAddress, t.endAddress, "Fahrt Wohnung – erste Tätigkeitsstätte")
        case .business:
            let parts = [t.purpose,
                         t.businessPartner.isEmpty ? nil : "Partner: \(t.businessPartner)",
                         t.detourNote.isEmpty ? nil : "Umweg: \(t.detourNote)"]
            return (t.startAddress, t.endAddress, parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        case .unassigned:
            return (t.startAddress, t.endAddress, "⚠︎ noch nicht zugeordnet")
        }
    }

    private static func timeText(_ t: Trip) -> String {
        "\(Fmt.time.string(from: t.startDate))–\(t.endDate.map { Fmt.time.string(from: $0) } ?? "")"
    }

    // MARK: - CSV

    static func csv(trips: [Trip], period: ExportPeriod) throws -> URL {
        let header = ["Datum", "Abfahrt", "Ankunft", "Km-Stand Beginn", "Km-Stand Ende", "Gefahrene km",
                      "Fahrtart", "Start", "Ziel", "Reisezweck", "Geschäftspartner", "Umweg/Bemerkung",
                      "Fahrzeug", "Status", "Festgeschrieben am", "Prüfsumme"]
        var lines = [header.map(escape).joined(separator: ";")]
        for t in trips {
            let f = fields(t)
            let isPrivate = t.category == .privateTrip
            let row = [
                Fmt.date.string(from: t.startDate), Fmt.time.string(from: t.startDate),
                t.endDate.map { Fmt.time.string(from: $0) } ?? "",
                String(t.startOdometer), t.endOdometer.map(String.init) ?? "", Fmt.kmValue(t.distanceKm),
                t.exportCategoryLabel, f.start, f.end,
                isPrivate ? "" : t.purpose, isPrivate ? "" : t.businessPartner, isPrivate ? "" : t.detourNote,
                t.vehicle, t.status.label, t.finalizedAt.map { Fmt.dateTime.string(from: $0) } ?? "", t.integrityHash,
            ]
            lines.append(row.map(escape).joined(separator: ";"))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Fahrtenbuch_\(period.fileStem).csv")
        try ("\u{FEFF}" + lines.joined(separator: "\r\n")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func escape(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - PDF

    static func pdf(trips: [Trip], period: ExportPeriod, audit: [AuditEntry], expenses: [Expense] = []) throws -> URL {
        let page = CGRect(x: 0, y: 0, width: 842, height: 595) // A4 quer
        let margin: CGFloat = 30
        let usableBottom = page.height - margin - 16

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "Fahrtenbuch \(period.title)",
                               kCGPDFContextCreator as String: "Fahrtenbuch-App"]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7.5), .paragraphStyle: paragraph]
        let bold: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 7.5), .paragraphStyle: paragraph]
        let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 15)]
        let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]
        let text: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]

        let tripColumns: [(String, CGFloat)] = [
            ("Datum", 52), ("Zeit", 56), ("Km Beginn", 50), ("Km Ende", 50), ("km", 38), ("Art", 70),
            ("Start", 140), ("Ziel", 140), ("Reisezweck · Geschäftspartner · Umweg", 186),
        ]
        let auditColumns: [(String, CGFloat)] = [
            ("Zeitpunkt", 80), ("Fahrt", 170), ("Feld", 100), ("Alter Wert", 216), ("Neuer Wert", 216),
        ]

        let data = renderer.pdfData { ctx in
            var y: CGFloat = 0
            var pageNumber = 0

            func newPage(heading: String) {
                ctx.beginPage()
                pageNumber += 1
                y = margin
                (heading as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: title)
                y += 20
                let sub = "Fahrzeug: \(AppSettings.vehicleDisplayName)   ·   Zeitraum: \(period.title)   ·   erstellt am \(Fmt.dateTime.string(from: .now))"
                (sub as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: small)
                y += 18
                let footer = "Seite \(pageNumber)   ·   Fahrtenbuch mit GPS-Aufzeichnung und Änderungsprotokoll   ·   \(AppInfo.shortDisclaimer)"
                (footer as NSString).draw(at: CGPoint(x: margin, y: page.height - margin), withAttributes: small)
            }

            func rowHeight(_ values: [String], _ columns: [(String, CGFloat)], _ attrs: [NSAttributedString.Key: Any]) -> CGFloat {
                let heights = zip(values, columns).map { value, column in
                    (value as NSString).boundingRect(with: CGSize(width: column.1 - 6, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin], attributes: attrs, context: nil).height
                }
                return ceil(heights.max() ?? 9) + 6
            }

            func drawRow(_ values: [String], _ columns: [(String, CGFloat)], _ attrs: [NSAttributedString.Key: Any],
                         fill: UIColor?, height: CGFloat) {
                if let fill {
                    fill.setFill()
                    UIRectFill(CGRect(x: margin, y: y, width: page.width - 2 * margin, height: height))
                }
                var x = margin
                for (value, column) in zip(values, columns) {
                    (value as NSString).draw(with: CGRect(x: x + 3, y: y + 3, width: column.1 - 6, height: height - 6),
                                             options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
                    x += column.1
                }
                y += height
            }

            func table(_ heading: String, _ columns: [(String, CGFloat)], _ rows: [[String]]) {
                let headerValues = columns.map(\.0)
                let headerHeight = rowHeight(headerValues, columns, bold)
                newPage(heading: heading)
                drawRow(headerValues, columns, bold, fill: UIColor(white: 0.85, alpha: 1), height: headerHeight)
                for (index, values) in rows.enumerated() {
                    let h = rowHeight(values, columns, body)
                    if y + h > usableBottom {
                        newPage(heading: heading)
                        drawRow(headerValues, columns, bold, fill: UIColor(white: 0.85, alpha: 1), height: headerHeight)
                    }
                    drawRow(values, columns, body, fill: index.isMultiple(of: 2) ? UIColor(white: 0.96, alpha: 1) : nil, height: h)
                }
            }

            // 1) Fahrten
            let tripRows = trips.map { t -> [String] in
                let f = fields(t)
                return [Fmt.date.string(from: t.startDate), timeText(t), String(t.startOdometer),
                        t.endOdometer.map(String.init) ?? "", Fmt.kmValue(t.distanceKm), t.exportCategoryLabel,
                        f.start, f.end, f.purpose]
            }
            table("Fahrtenbuch", tripColumns, tripRows)

            // 2) Zusammenfassung
            func km(_ c: TripCategory) -> Double { trips.filter { $0.category == c }.reduce(0) { $0 + $1.distanceKm } }
            let total = trips.reduce(0) { $0 + $1.distanceKm }
            let share = total > 0 ? km(.business) / total * 100 : 0
            var summary = [
                "Gesamt: \(Fmt.km(total)) in \(trips.count) Fahrten",
                "Dienstfahrten: \(Fmt.km(km(.business))) (\(String(format: "%.1f", share).replacingOccurrences(of: ".", with: ",")) %)",
                "Privatfahrten: \(Fmt.km(km(.privateTrip)))",
                "Wohnung–Arbeitsstätte: \(Fmt.km(km(.commute)))",
            ]
            if km(.unassigned) > 0 { summary.append("Noch nicht zugeordnet: \(Fmt.km(km(.unassigned)))") }
            if let first = trips.first, let last = trips.last {
                summary.append("Km-Stand zu Beginn: \(first.startOdometer) · am Ende: \(last.endOdometer ?? last.startOdometer)")
            }
            let money = Reimbursement(trips: trips)
            if money.total > 0 {
                summary.append("Fahrtgeld Dienstfahrten: \(Fmt.km(money.businessKm)) × \(Fmt.euro(Reimbursement.businessRate)) = \(Fmt.euro(money.businessAmount))")
                if money.commuteAmount > 0 {
                    summary.append("Fahrtgeld Arbeitsweg: \(money.commuteExplanation) = \(Fmt.euro(money.commuteAmount))")
                }
                summary.append("Fahrtgeld gesamt: \(Fmt.euro(money.total))")
            }
            if !expenses.isEmpty {
                let costs = CostSummary(expenses)
                summary.append("Fahrzeugkosten laut Belegen: \(Fmt.euro(costs.total))"
                               + (costs.costPerKm(total).map { " · \(Fmt.euro($0)) je km" } ?? ""))
                if total > 0 {
                    summary.append("Davon rechnerisch auf Dienstfahrten entfallend: \(Fmt.euro(costs.total * km(.business) / total))")
                }
            }
            let finalized = trips.filter { $0.status == .finalized }
            summary.append("Festgeschrieben: \(finalized.count) von \(trips.count) Fahrten")
            if let lastHash = finalized.max(by: { ($0.finalizedAt ?? .distantPast) < ($1.finalizedAt ?? .distantPast) })?.integrityHash {
                summary.append("Prüfsumme der zuletzt festgeschriebenen Fahrt: \(lastHash)")
            }

            let blockHeight = CGFloat(summary.count) * 14 + 30
            if y + blockHeight > usableBottom { newPage(heading: "Fahrtenbuch") }
            y += 14
            ("Zusammenfassung" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 11)])
            y += 18
            for line in summary {
                (line as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: text)
                y += 14
            }

            // 3) Änderungsprotokoll
            if !audit.isEmpty {
                let auditRows = audit.map { [Fmt.dateTime.string(from: $0.timestamp), $0.tripLabel, $0.field,
                                             $0.oldValue.isEmpty ? "(leer)" : $0.oldValue,
                                             $0.newValue.isEmpty ? "(leer)" : $0.newValue] }
                table("Änderungsprotokoll", auditColumns, auditRows)
            }

            // 4) Fahrzeugkosten
            if !expenses.isEmpty {
                let costColumns: [(String, CGFloat)] = [
                    ("Datum", 70), ("Art", 130), ("Anbieter", 220), ("Menge", 90), ("Km-Stand", 90), ("Betrag", 90), ("Notiz", 92),
                ]
                let costRows = expenses.map { e in
                    [Fmt.date.string(from: e.date), e.kind.label, e.vendor,
                     e.quantity > 0 ? "\(Fmt.kmValue(e.quantity)) \(e.kind.quantityUnit)" : "",
                     e.odometer > 0 ? String(e.odometer) : "", Fmt.euro(e.amount), e.note]
                }
                table("Fahrzeugkosten (Belege)", costColumns, costRows)
            }
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Fahrtenbuch_\(period.fileStem).pdf")
        try data.write(to: url)
        return url
    }
}
