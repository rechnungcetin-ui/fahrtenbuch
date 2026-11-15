import Foundation
import Security

/// Buchungskonto aus sevDesk samt erlaubter Steuerregeln.
struct SevDeskAccount: Codable, Identifiable, Hashable {
    struct TaxRule: Codable, Hashable {
        let id: Int
        let name: String
        let rates: [Double]
    }

    let id: Int
    let number: String
    let name: String
    let taxRules: [TaxRule]

    var label: String { "\(number) · \(name)" }

    func taxRuleID(for rate: Double) -> Int {
        taxRules.first { $0.rates.contains(rate) }?.id ?? taxRules.first?.id ?? 9
    }
}

enum SevDeskError: LocalizedError {
    case noToken, invalidResponse, unsupportedVersion(String), http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noToken: "Bitte zuerst den sevDesk-API-Token in den Einstellungen hinterlegen."
        case .invalidResponse: "Unerwartete Antwort von sevDesk."
        case .unsupportedVersion(let v): "Dein sevDesk nutzt Buchhaltungsversion \(v). Unterstützt wird sevDesk 2.0."
        case .http(let code, let message):
            code == 401 ? "sevDesk hat den API-Token abgelehnt." : "sevDesk-Fehler \(code): \(message)"
        }
    }
}

/// Der API-Token liegt im Schlüsselbund des iPhones – nicht in den Einstellungen und nicht in iCloud.
enum Keychain {
    private static let service = "de.meinfahrtenbuch.app"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Anbindung an sevDesk: legt Belege als **Entwurf** an – gebucht wird erst, wenn du sie in sevDesk bestätigst.
enum SevDeskClient {
    private static let base = "https://my.sevdesk.de/api/v1"
    private static let tokenKey = "sevDeskToken"

    static var token: String? {
        get { Keychain.get(tokenKey) }
        set { Keychain.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), for: tokenKey) }
    }

    static var isConfigured: Bool { !(token ?? "").isEmpty }

    // MARK: - Abfragen

    /// Prüft den Token und liefert die Buchhaltungsversion („2.0“).
    static func bookkeepingVersion() async throws -> String {
        let json = try await send(path: "/Tools/bookkeepingSystemVersion")
        guard let objects = json["objects"] as? [String: Any], let version = objects["version"] as? String else {
            throw SevDeskError.invalidResponse
        }
        return version
    }

    /// Alle Aufwandskonten, die sevDesk für Ausgabenbelege erlaubt.
    static func expenseAccounts() async throws -> [SevDeskAccount] {
        let json = try await send(path: "/ReceiptGuidance/forExpense")
        guard let objects = json["objects"] as? [[String: Any]] else { throw SevDeskError.invalidResponse }
        return objects.compactMap { object in
            guard let id = int(object["accountDatevId"]) else { return nil }
            let rules = (object["allowedTaxRules"] as? [[String: Any]] ?? []).compactMap { rule -> SevDeskAccount.TaxRule? in
                guard let ruleID = int(rule["id"]) else { return nil }
                let rates = (rule["taxRates"] as? [Any] ?? []).compactMap { double($0) }
                return .init(id: ruleID, name: rule["name"] as? String ?? "", rates: rates)
            }
            return SevDeskAccount(id: id, number: string(object["accountNumber"]), name: object["accountName"] as? String ?? "",
                                  taxRules: rules)
        }
        .sorted { $0.number < $1.number }
    }

    // MARK: - Beleg anlegen

    /// Legt einen Ausgabenbeleg als Entwurf an und hängt optional eine Datei (PDF/JPG) an. Liefert die Beleg-ID.
    static func createDraftVoucher(date: Date, supplier: String, description: String, amount: Double, taxRate: Double,
                                   account: SevDeskAccount, comment: String,
                                   file: (data: Data, name: String, mimeType: String)?) async throws -> String {
        var filename: Any = NSNull()
        if let file { filename = try await upload(file.data, name: file.name, mimeType: file.mimeType) }

        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]

        let body: [String: Any] = [
            "voucher": [
                "objectName": "Voucher", "mapAll": true,
                "voucherDate": day.string(from: date),
                "supplierName": supplier,
                "description": description,
                "status": 50,               // 50 = Entwurf
                "creditDebit": "C",         // Ausgabe
                "voucherType": "VOU",
                "currency": "EUR",
                "taxRule": ["id": account.taxRuleID(for: taxRate), "objectName": "TaxRule"],
            ] as [String: Any],
            "voucherPosSave": [[
                "objectName": "VoucherPos", "mapAll": true,
                "accountDatev": ["id": account.id, "objectName": "AccountDatev"],
                "taxRate": taxRate,
                "net": false,
                "sumGross": (amount * 100).rounded() / 100,
                "comment": comment,
            ] as [String: Any]],
            "voucherPosDelete": NSNull(),
            "filename": filename,
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(path: "/Voucher/Factory/saveVoucher", method: "POST", body: data, contentType: "application/json")
        guard let objects = json["objects"] as? [String: Any], let voucher = objects["voucher"] as? [String: Any] else {
            throw SevDeskError.invalidResponse
        }
        return string(voucher["id"])
    }

    private static func upload(_ data: Data, name: String, mimeType: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let json = try await send(path: "/Voucher/Factory/uploadTempFile", method: "POST", body: body,
                                  contentType: "multipart/form-data; boundary=\(boundary)")
        guard let objects = json["objects"] as? [String: Any], let filename = objects["filename"] as? String else {
            throw SevDeskError.invalidResponse
        }
        return filename
    }

    // MARK: - HTTP

    private static func send(path: String, method: String = "GET", body: Data? = nil,
                             contentType: String? = nil) async throws -> [String: Any] {
        guard let token, !token.isEmpty else { throw SevDeskError.noToken }
        guard let url = URL(string: base + path) else { throw SevDeskError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
                ?? json?["message"] as? String
                ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw SevDeskError.http(status, message)
        }
        guard let json else { throw SevDeskError.invalidResponse }
        return json
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func string(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}

extension ExpenseKind {
    /// Üblicher Umsatzsteuersatz – im sevDesk-Entwurf jederzeit änderbar.
    var defaultTaxRate: Double {
        switch self {
        case .insurance, .tax, .depreciation: 0
        default: 19
        }
    }
}
