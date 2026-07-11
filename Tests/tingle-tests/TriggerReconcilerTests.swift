import Foundation
import TingleCore

func runTriggerReconcilerTests() {
    do { // edges drive belief; duplicates rejected
        var r = TriggerReconciler()
        expect(r.apply(edgeDown: true), "reconciler: first down accepted")
        expect(r.held, "reconciler: held after down")
        expect(!r.apply(edgeDown: true), "reconciler: duplicate down rejected")
        expect(r.apply(edgeDown: false), "reconciler: up accepted")
        expect(!r.held, "reconciler: released after up")
    }
    do { // agreeing beacons are no-ops
        var r = TriggerReconciler()
        expectEqual(r.reconcile(beaconSaysHeld: false), .none, "reconciler: agree released")
        _ = r.apply(edgeDown: true)
        expectEqual(r.reconcile(beaconSaysHeld: true), .none, "reconciler: agree held")
    }
    do { // lost release: beacon heals within one heartbeat
        var r = TriggerReconciler()
        _ = r.apply(edgeDown: true)
        expectEqual(r.reconcile(beaconSaysHeld: false), .synthesizeUp,
                    "reconciler: stuck-held heals to released")
    }
    do { // lost press (or USB plug-in mid-squeeze): heals the other way
        var r = TriggerReconciler()
        expectEqual(r.reconcile(beaconSaysHeld: true), .synthesizeDown,
                    "reconciler: stuck-released heals to held")
    }
    do { // the USB plug-in scenario end to end: stale held belief carried
         // across a backend handover, then the first serial beacon lands
        var r = TriggerReconciler()
        _ = r.apply(edgeDown: true)          // audio-mode squeeze…
        // …release edge lost during the serial handover…
        expectEqual(r.reconcile(beaconSaysHeld: false), .synthesizeUp,
                    "reconciler: plug-in desync heals")
        _ = r.apply(edgeDown: false)         // the synthesized edge lands
        expectEqual(r.reconcile(beaconSaysHeld: false), .none,
                    "reconciler: converged after heal")
    }
}
