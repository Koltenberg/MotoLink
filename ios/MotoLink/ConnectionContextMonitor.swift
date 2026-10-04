import AVFAudio
import Foundation
import Network

/// Passive, best-effort context for a ride's BLE diagnostics. An audio session's
/// route is not an inventory of connected accessories: an empty route does not
/// establish that Sena is absent. This class never activates or configures audio.
/// State and callbacks are confined to the main queue, like the ride recorder.
final class ConnectionContextMonitor {
    private struct Context: Equatable {
        let inputs: [String]
        let outputs: [String]
        let otherAudioPlaying: Bool
        let interruption: String
        let mediaResetCount: Int
    }

    private let onEvent: (String) -> Void
    private var observers: [NSObjectProtocol] = []
    private var recording = false
    private var previousContext: Context?
    private var interruption = "unknown"
    private var mediaResetCount = 0
    private var emittedCount = 0
    private var reportedLimit = false
    // A pathological notification burst must not grow the ride log indefinitely.
    // One final limit marker may follow these context events. No history is kept.
    private let eventLimit = 120

    init(onEvent: @escaping (String) -> Void) {
        self.onEvent = onEvent
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, self.recording else { return }
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            self.snapshot(reason: "route_changed_\(reason.map { String($0) } ?? "unknown")")
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, self.recording else { return }
            let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began?: self.interruption = "active"
            case .ended?: self.interruption = "inactive"
            default: self.interruption = "unknown"
            }
            // An interruption does not identify a phone call, Siri, or its cause.
            self.snapshot(reason: "audio_interruption")
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.recording, !self.reportedLimit else { return }
            self.mediaResetCount += 1
            self.interruption = "unknown"
            self.snapshot(reason: "media_services_reset")
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func setRecording(_ enabled: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setRecording(enabled) }
            return
        }
        guard recording != enabled else { return }
        recording = enabled
        previousContext = nil
        interruption = "unknown"
        mediaResetCount = 0
        emittedCount = 0
        reportedLimit = false
        if enabled { snapshot(reason: "recording_started") }
    }

    /// Called at session boundaries or on demand; unchanged context is omitted.
    /// No timer, Bluetooth discovery, WatchConnectivity activation, microphone
    /// access, or audio-route mutation is used to obtain this evidence.
    func snapshot(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.snapshot(reason: reason) }
            return
        }
        guard recording, !reportedLimit else { return }
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let context = Context(
            inputs: Array(Set(route.inputs.map { $0.portType.rawValue })).sorted(),
            outputs: Array(Set(route.outputs.map { $0.portType.rawValue })).sorted(),
            otherAudioPlaying: session.isOtherAudioPlaying,
            interruption: interruption,
            mediaResetCount: mediaResetCount
        )
        guard context != previousContext else { return }
        previousContext = context
        guard emittedCount < eventLimit else {
            reportedLimit = true
            onEvent("passive_audio_context event_limit=\(eventLimit) further_context_events_omitted=true accessory_presence=unknown")
            return
        }
        emittedCount += 1
        let safeReason = String(reason.prefix(64)).replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let inputs = context.inputs.isEmpty ? "unknown" : context.inputs.joined(separator: ",")
        let outputs = context.outputs.isEmpty ? "unknown" : context.outputs.joined(separator: ",")
        onEvent("passive_audio_context reason=\(safeReason) best_effort=true accessory_presence=unknown "
            + "input_port_types=[\(inputs)] output_port_types=[\(outputs)] "
            + "other_audio_playing=\(context.otherAudioPlaying) audio_interruption=\(context.interruption) "
            + "media_reset_count=\(context.mediaResetCount)")
    }
}

/// Observes only the system's selected network path while a ride is active.
/// NWPathMonitor does not initiate a network request or inspect Wi-Fi names,
/// addresses, or cellular identifiers. Changes are evidence, not BLE causes.
final class NetworkPathContextMonitor {
    private struct Context: Equatable {
        let status: String
        let interfaces: String
        let expensive: Bool
        let constrained: Bool
    }

    private let onEvent: (String) -> Void
    private var monitor: NWPathMonitor?
    private var generation = UUID()
    private var previousContext: Context?
    private var eventCount = 0
    private let eventLimit = 120

    init(onEvent: @escaping (String) -> Void) { self.onEvent = onEvent }

    deinit { monitor?.cancel() }

    func setRecording(_ enabled: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setRecording(enabled) }
            return
        }
        guard enabled != (monitor != nil) else { return }
        generation = UUID()
        monitor?.cancel()
        monitor = nil
        previousContext = nil
        eventCount = 0
        guard enabled else { return }
        let monitor = NWPathMonitor()
        let expected = generation
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, self.generation == expected else { return }
            self.observe(path)
        }
        self.monitor = monitor
        monitor.start(queue: .main)
    }

    private func observe(_ path: NWPath) {
        guard monitor != nil else { return }
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requires_connection"
        @unknown default: status = "unknown"
        }
        let interfaceTypes: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"),
            (.loopback, "loopback"), (.other, "other")
        ]
        let interfaces = interfaceTypes.filter { path.usesInterfaceType($0.0) }
            .map { $0.1 }.joined(separator: ",")
        let context = Context(status: status, interfaces: interfaces.isEmpty ? "none" : interfaces,
                              expensive: path.isExpensive, constrained: path.isConstrained)
        guard context != previousContext else { return }
        previousContext = context
        guard eventCount < eventLimit else {
            if eventCount == eventLimit {
                eventCount += 1
                onEvent("passive_network_path event_limit=\(eventLimit) further_path_events_omitted=true")
            }
            return
        }
        eventCount += 1
        onEvent("passive_network_path status=\(context.status) interfaces=\(context.interfaces) "
            + "expensive=\(context.expensive) constrained=\(context.constrained)")
    }
}
