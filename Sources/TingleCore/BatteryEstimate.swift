import Foundation

/// Rough state-of-charge for 2×AAA alkaline cells in series (the ting's
/// battery bay; per the manual it runs on AAs' little sibling and refuses
/// to start below ~2V pack). Alkaline discharge is famously non-linear:
/// a short fresh plateau near 1.55V/cell, a long middle around 1.2–1.3V,
/// then a cliff. Piecewise-linear over that curve — a heuristic, not a
/// coulomb counter, but good enough to know when to buy Duracells.
public enum BatteryEstimate {
    /// Pack voltage (2 cells) → estimated percent, clamped 0–100.
    public static func percent(packVolts: Double) -> Int {
        let v = packVolts / 2.0   // per cell
        // (voltage, percent) knees, descending.
        let curve: [(Double, Double)] = [
            (1.60, 100), (1.55, 100), (1.45, 90), (1.35, 75),
            (1.25, 55), (1.20, 40), (1.15, 25), (1.10, 12),
            (1.05, 5), (1.00, 2), (0.95, 0),
        ]
        if v >= curve.first!.0 { return 100 }
        if v <= curve.last!.0 { return 0 }
        for i in 1..<curve.count where v > curve[i].0 {
            let (hiV, hiP) = curve[i - 1]
            let (loV, loP) = curve[i]
            let t = (v - loV) / (hiV - loV)
            return Int((loP + t * (hiP - loP)).rounded())
        }
        return 0
    }
}
