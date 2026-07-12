import Foundation

/// Shared preferences domain for BOTH the installed .app and the bare dev
/// binary. UserDefaults.standard splits them (bundle id vs process name),
/// which caused two live bugs on 2026-07-11: a stale input pin haunting
/// only the dev build, and the dev build re-offering a firmware upgrade
/// the installed app had already done. One domain, one truth.
enum Prefs {
    static let suite = UserDefaults(suiteName: "com.tutorintelligence.tingle") ?? .standard

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
