import Foundation
import AVFoundation

/// Erkennt, ob das iPhone mit dem Auto (Bluetooth-Audio / CarPlay) verbunden ist.
///
/// Wichtig: iOS informiert Apps nur über Audio-Routenwechsel, solange die App läuft.
/// Für den zuverlässigen Start im Hintergrund dient die Kurzbefehle-Automation (siehe README / Einstellungen).
@MainActor
final class CarAudioMonitor {
    static let shared = CarAudioMonitor()

    private var observer: NSObjectProtocol?
    private var wasConnected = false

    private static let carPorts: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio]

    /// Name des aktuell verbundenen Bluetooth-/CarPlay-Geräts, falls vorhanden.
    static func connectedDeviceName() -> String? {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .first { carPorts.contains($0.portType) }?
            .portName
    }

    static func isConfiguredCarConnected() -> Bool {
        let wanted = AppSettings.carBluetoothName.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, let name = connectedDeviceName() else { return false }
        return name.localizedCaseInsensitiveContains(wanted)
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate()
    }

    func evaluate() {
        guard AppSettings.autoDetectBluetooth else { return }
        let connected = Self.isConfiguredCarConnected()
        let recorder = TripRecorder.shared

        if connected && !wasConnected && !recorder.isRecording {
            recorder.startTrip(trigger: .bluetooth)
        } else if !connected && wasConnected && recorder.isRecording && AppSettings.stopOnDisconnect {
            recorder.stopTrip(reason: .bluetooth)
        }
        wasConnected = connected
    }
}
