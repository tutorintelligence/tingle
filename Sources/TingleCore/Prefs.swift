import Foundation

/// Shared preferences domain for BOTH the installed .app and the bare dev
/// binary. UserDefaults.standard splits them (bundle id vs process name),
/// which caused two live bugs on 2026-07-11: a stale input pin haunting
/// only the dev build, and the dev build re-offering a firmware upgrade
/// the installed app had already done. One domain, one truth.
enum Prefs {
    static let suite = UserDefaults(suiteName: "com.tutorintelligence.tingle") ?? .standard
}
