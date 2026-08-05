import Foundation

/// Shared preferences domain for BOTH the installed .app and the bare dev
/// binary. UserDefaults.standard splits them (bundle id vs process name),
/// which caused two live bugs on 2026-07-11: a stale input pin haunting
/// only the dev build, and the dev build re-offering a firmware upgrade
/// the installed app had already done. One domain, one truth.
public enum Prefs {
    public static let suite = UserDefaults(suiteName: "com.tutorintelligence.tingle") ?? .standard

    /// Firmware bookkeeping is PER DEVICE: the flag records what tingle
    /// last flashed onto a specific ting (identified by its USB serial
    /// suffix). A global flag once marked a brand-new device as upgraded
    /// because a DIFFERENT ting had been (2026-08-05) — the new unit's
    /// shipped firmware then corrupted every button chirp over 3.5mm.
    public static func lastFlashedFirmware(serial: String?) -> String? {
        guard let serial else { return nil }
        return suite.string(forKey: "lastFlashedFirmware.\(serial)")
    }

    public static func setLastFlashedFirmware(_ version: String, serial: String?) {
        guard let serial else { return }
        suite.set(version, forKey: "lastFlashedFirmware.\(serial)")
    }

    /// Beacon level (dBFS) of the last pilot lock — seeds the detector's
    /// single-beacon fast re-lock across backend AND app restarts.
    static var lastBeaconLevelDB: Double? {
        get { suite.object(forKey: "lastBeaconLevelDB") as? Double }
        set {
            if let newValue { suite.set(newValue, forKey: "lastBeaconLevelDB") }
            else { suite.removeObject(forKey: "lastBeaconLevelDB") }
        }
    }
}
