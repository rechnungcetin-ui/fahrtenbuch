import Foundation
import SwiftData

/// Jede Änderung wird protokolliert, damit nachvollziehbar bleibt, was wann geändert wurde.
@Model
final class AuditEntry {
    var timestamp: Date = Date.now
    var field: String = ""
    var oldValue: String = ""
    var newValue: String = ""
    /// Kopie der Fahrtbezeichnung, damit der Eintrag auch nach dem Löschen der Fahrt verständlich bleibt.
    var tripLabel: String = ""
    var trip: Trip?

    init(field: String, oldValue: String, newValue: String, tripLabel: String) {
        self.timestamp = .now
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.tripLabel = tripLabel
    }
}
