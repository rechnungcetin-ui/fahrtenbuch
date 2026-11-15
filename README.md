# Fahrtenbuch – iOS-App

Automatisches Fahrtenbuch fürs iPhone: Die App erkennt Autofahrten selbst, zeichnet Route und Kilometer auf, ordnet Fahrten vor, zeigt dir die Anteile geschäftlich / privat / Arbeitsweg, rechnet dein Fahrtgeld aus und erstellt PDF und CSV. Belege und Fahrtgeld gehen auf Wunsch als Entwurf an sevDesk.

**Technik:** SwiftUI · SwiftData + iCloud · CoreLocation · CoreMotion · MapKit · Vision · App Intents · iOS 17+
**Laufende Kosten:** keine Server, keine API-Gebühren. Nötig ist nur das Apple-Entwicklerkonto (siehe unten).

> **Stand:** Gebaut wird automatisch über GitHub Actions. Die sevDesk-Anbindung ist nach der Dokumentation geschrieben und noch nicht mit einem echten Konto getestet.

---

## 1. Aufs iPhone bringen

GitHub baut die App bei jedem Push automatisch auf einem Mac in der Cloud. Die fertige Datei **`Fahrtenbuch.ipa`** liegt danach im Repository unter **Releases → latest** (und bei jedem Build unter *Actions → Artifacts*).

Eine `.ipa` muss vor der Installation mit einer Apple-ID signiert werden – das übernimmt ein kleines Programm auf dem Computer:

### Weg A: Kostenlos mit deiner Apple-ID (Sideloadly, Windows oder Mac)

1. **Sideloadly** von sideloadly.io installieren (unter Windows zusätzlich iTunes und iCloud von Apple, nicht aus dem Microsoft Store).
2. `Fahrtenbuch.ipa` aus *Releases → latest* herunterladen.
3. iPhone per Kabel anschließen, `.ipa` in Sideloadly ziehen, Apple-ID eingeben, **Start**.
4. Auf dem iPhone: *Einstellungen → Datenschutz & Sicherheit → Entwicklermodus* einschalten (Neustart), dann *Einstellungen → Allgemein → VPN & Geräteverwaltung* → deiner Apple-ID vertrauen.

Einschränkungen mit kostenloser Apple-ID: Die App läuft **7 Tage** und muss dann erneut über Sideloadly installiert werden (deine Daten bleiben erhalten). **iCloud-Sync ist dabei nicht verfügbar** – die App speichert lokal und legt das Monatsarchiv in der Dateien-App ab.

### Weg B: Dauerhaft mit Apple Developer Program (99 €/Jahr)

Damit läuft die App dauerhaft, iCloud-Sync funktioniert, und du kannst sie über **TestFlight** installieren oder im **App Store** anbieten. Dafür wird der Build um Signatur und TestFlight-Upload erweitert (App Store Connect API-Schlüssel als GitHub-Secret).

### Weg C: Mit einem Mac

```bash
brew install xcodegen
```

```bash
cd Fahrtenbuch && xcodegen generate && open Fahrtenbuch.xcodeproj
```

In Xcode: Target **Fahrtenbuch → Signing & Capabilities → Team** wählen, iPhone anschließen, ▶︎ drücken. Mit kostenloser Apple-ID vorher in `project.yml` den Block `entitlements:` löschen.

## 2. Einrichtung auf dem iPhone

1. Standort **„Immer“**, Bewegung, Mitteilungen und Kalender erlauben.
2. **Einstellungen → Fahrzeug:** Name, Kennzeichen, aktueller Kilometerstand laut Tacho.
3. **Einstellungen → Wohnung & Arbeitsstätte:** beide Adressen eintragen. Die Entfernung wird automatisch berechnet.
4. **Einstellungen → Fahrtgeld:** Sätze prüfen (voreingestellt 0,30 € Dienstfahrten, 0,38 € Arbeitsweg).
5. Optional: **sevDesk** verbinden, Kurzbefehl für Auto-Bluetooth einrichten, Kunden als Orte speichern.

Danach einfach losfahren.

## 3. Funktionen

| Bereich | Was die App kann |
|---|---|
| **Fahrterkennung** | Ohne Bluetooth: Geofence um den Parkplatz + Bewegungssensor + Geschwindigkeit (ab 20 km/h, einstellbar). Fahrrad wird ausgeschlossen. Der Anfang der Strecke wird vom Parkplatz aus ergänzt. Ende nach 1 Minute Fußweg oder X Minuten Stillstand. Optional exakt per Kurzbefehl „Bluetooth verbunden“. |
| **Automatische Zuordnung** | Gespeicherter Ort → Kalendertermin → Rückfahrt → bekannte Strecke → Arbeitszeit. Die Regel steht an der Fahrt, alles bleibt änderbar. |
| **Mitteilungen** | Nach jeder Fahrt direkt zuordnen (Geschäftlich / Privat / Arbeitsweg / Nicht selbst gefahren). Abends Erinnerung an offene Fahrten. |
| **Fahrtgeld** | Satz je Kilometer für Dienstfahrten, eigener Satz für den Arbeitsweg (Entfernungspauschale: einfache Strecke je Arbeitstag, oder jeder gefahrene Kilometer). Monatssumme auf der Startseite, in der Auswertung und im PDF. |
| **Belege** | Tank- und Werkstattbelege scannen; Betrag, Liter, Datum und Anbieter werden erkannt. Tachostand vom Beleg gleicht den Kilometerstand ab. Kosten je km und Verbrauch. |
| **Fahrten bearbeiten** | Zusammenführen (Zwischenstopp), Nachtragen (mit Grund, gekennzeichnet), Orte speichern. |
| **Auswertung** | Nutzungsanteile (geschäftlich / Arbeitsweg / privat), Fahrtgeld, Kosten je km und eine Orientierung, was absetzbar sein kann – für privates Auto (Pauschale) und Firmenauto (tatsächliche Kosten). |
| **Nachvollziehbarkeit** | Lückenlose Kilometerstände, Änderungsprotokoll, Festschreiben nach 7 Tagen, Prüfsummen, PDF- und CSV-Export. |
| **Datensicherung** | iCloud-Sync (privater Bereich) und automatisches Monatsarchiv als PDF + CSV in der Dateien-App. |
| **sevDesk** | Fahrtgeld des Monats als Eigenbeleg mit Fahrtenbuch-PDF im Anhang; Kfz-Belege mit Foto. Alles als **Entwurf** – gebucht wird erst in sevDesk. |

## 4. Fahrtgeld und Steuer – was die Voreinstellungen bedeuten

- **Dienstfahrten mit privatem Pkw:** 0,30 € je gefahrenem Kilometer.
- **Wohnung ↔ erste Betriebs-/Tätigkeitsstätte:** Entfernungspauschale 0,38 € je Kilometer der **einfachen** Strecke, einmal pro Arbeitstag, nur volle Kilometer (seit 2026 ab dem ersten Kilometer).
- **Entweder Pauschale oder tatsächliche Kosten:** Die Kilometerpauschale gilt für ein privates Auto. Gehört das Auto zum Betriebsvermögen, setzt du die tatsächlichen Kosten an und brauchst das Fahrtenbuch für den Privatanteil – die 0,30 € für Dienstfahrten kommen dann nicht zusätzlich dazu. Für diesen Fall zeigt die Auswertung die Kosten laut Belegen und den Anteil der Dienstfahrten.
- Die Sätze sind frei einstellbar, falls du mit einem Auftraggeber andere Beträge vereinbart hast.

Die App ist ein Hilfsmittel zur Dokumentation, **keine Steuerberatung**, und macht keine Zusage, dass ein Fahrtenbuch vom Finanzamt anerkannt wird. In der App, in der Auswertung und im PDF steht dazu der Hinweis „Alle Angaben ohne Gewähr · keine Steuerberatung“.

## 5. sevDesk einrichten

1. In sevDesk: Einstellungen › Benutzer › dein Benutzer › **API-Token** kopieren.
2. In der App: Einstellungen › Buchhaltung › sevDesk › Token einfügen › „Verbindung testen“.
3. Zwei Konten wählen: eines für Fahrtgeld (üblich SKR03 4673 / SKR04 6673), eines für Kfz-Belege (üblich 4530 / 6530).
4. Senden: Fahrtgeld in *Auswertung* (Monat wählen), Belege im jeweiligen Beleg.

Der Token liegt nur im Schlüsselbund des iPhones. Unterstützt wird sevDesk mit Buchhaltungsversion 2.0.

## 6. In den App Store

Technisch ist die App darauf vorbereitet (Icon, Datenschutz-Manifest, Berechtigungstexte). Zusätzlich brauchst du:

1. **Apple Developer Program** (99 €/Jahr), als Einzelperson oder Unternehmen.
2. **Eigene Bundle-ID und iCloud-Container** in `project.yml` (`de.meinfahrtenbuch.app` ersetzen).
3. **Datenschutzerklärung und Impressum** auf einer Webseite, Support-Adresse.
4. **Begründung für Standort „Immer“** in der App-Prüfung; Apple schaut hier genau hin. Ein kurzes Demo-Video hilft.
5. **Screenshots, Beschreibung, Preis.** Für Abos oder Einmalkauf muss noch ein Kaufsystem (StoreKit) eingebaut werden.
6. **Keine Steuer-Versprechen in der Werbung:** Die App wird als Fahrtenbuch zur Dokumentation beschrieben, nicht als „finanzamtkonform“. Haftungsausschluss in AGB und App-Beschreibung aufnehmen.
7. **Vorher testen:** mehrere Wochen im eigenen Alltag und mit einigen Testern über TestFlight.

## 7. Projektstruktur

```
Fahrtenbuch/
├── App/        Start, Tabs, Einstellungen-Speicher
├── Models/     Trip · AuditEntry · SavedPlace · Expense · DataStore (SwiftData + iCloud)
├── Services/   TripRecorder (Erkennung + GPS) · AutoClassifier (Regeln) · PlaceMatcher · CalendarSuggester
│               TripLedger (Änderungen, Festschreiben, Prüfsummen) · Reimbursement (Fahrtgeld)
│               ExportService (PDF/CSV) · ArchiveService (Monatsarchiv) · ReceiptScanner (Belege lesen)
│               SevDeskClient · NotificationService · AddressResolver · CarAudioMonitor
├── Intents/    „Fahrt starten“ / „Fahrt beenden“ für Kurzbefehle und Siri
└── Views/      Heute · Fahrten · Belege · Auswertung · Einstellungen · sevDesk · Protokoll
```

## 8. Noch offen

- Erster Build und Test auf einem echten iPhone, danach Feinschliff der Erkennung
- Bluetooth-Beacon im Auto (schließt Bus und Bahn sicher aus)
- Mehrere Fahrzeuge
- Kaufsystem für den App-Store-Verkauf
- Widget / Live-Anzeige der laufenden Fahrt
