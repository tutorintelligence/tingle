import Foundation

/// A detected ting gesture, normalized across backends (see DESIGN.md: the
/// flashed device/tingle_main.py event engine emits these over serial as
/// "EVT ..." lines and over the line-out as tone-burst chirps).
///
/// mode is 1-4 (sam_pos + 1). preset is the FX slot (-1 = clean, 0-3); nil
/// when unknown (the audio backend cannot recover the preset number from the
/// chirp).
public enum TingEvent: Equatable {
    case whitePress(mode: Int)
    case whiteRelease(mode: Int)
    case modeChanged(mode: Int)
    case fxChanged(preset: Int?)
    /// Handle squeezed. Squeezing also enables the ting's own mic, so this
    /// is the push-to-talk control.
    case triggerDown
    /// Handle released (mic off).
    case triggerUp
    /// Heartbeat (~2s while the device's chirp queue is idle). An internal
    /// liveness/auto-discovery signal consumed by the coordinator — never
    /// routed to user actions and not user-mappable.
    case beacon
    /// Beacon variant emitted while the handle is held — carries live
    /// trigger state so a lost trigger chirp self-heals within ~2s.
    case beaconHeld
    /// A beacon detected from a single surviving tone (the partner tone
    /// drowned). Proves the ting is alive but the handle state is
    /// AMBIGUOUS — a released-beacon's second tone is indistinguishable
    /// from a held-beacon's first. Presence only; never a trigger hint.
    case beaconSensed
    /// Legacy: the abandoned triple-squeeze gesture (kept decodable for
    /// old device payloads; unmapped by default).
    case eraseGesture

    /// The config mappings key this event fires, or nil if not mappable
    /// (white release is deferred until hold/PTT semantics land; beacon is
    /// internal-only).
    public var mappingKey: String? {
        switch self {
        case .whitePress(let mode): return "mode\(mode)"
        case .whiteRelease: return nil
        case .modeChanged: return "modeChange"
        case .fxChanged: return "fxChange"
        case .triggerDown: return "triggerDown"
        case .triggerUp: return "triggerUp"
        case .beacon: return nil
        case .beaconHeld: return nil
        case .beaconSensed: return nil
        case .eraseGesture: return "tripleSqueeze"
        }
    }

    public var logDescription: String {
        switch self {
        case .whitePress(let mode): return "whitePress(mode: \(mode))"
        case .whiteRelease(let mode): return "whiteRelease(mode: \(mode))"
        case .modeChanged(let mode): return "modeChanged(mode: \(mode))"
        case .fxChanged(let preset): return "fxChanged(preset: \(preset.map(String.init) ?? "unknown"))"
        case .triggerDown: return "triggerDown"
        case .triggerUp: return "triggerUp"
        case .beacon: return "beacon"
        case .beaconHeld: return "beacon(held)"
        case .beaconSensed: return "beacon(state unknown)"
        case .eraseGesture: return "eraseGesture(triple squeeze)"
        }
    }
}
