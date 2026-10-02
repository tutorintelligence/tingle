import AppKit
import CryptoKit
import IOKit
import os

/// Guided ting firmware upgrade. The RP2350's bootloader is ROM-resident,
/// so this is effectively unbrickable: worst case, redo the bootloader
/// ritual and flash again.
///
/// Flow (driven from the menu, status streamed to the UI):
///   1. Download TE's official firmware zip (pinned URL + SHA-256), unzip
///      the .uf2.
///   2. Walk the user through TE's ritual (from the firmware readme):
///      lid off, USB attached, HOLD the handle, and while holding,
///      double-click the small button above the USB port — a "TING BOOT"
///      volume appears containing INFO_UF2.TXT.
///   3. Copy the .uf2 there. The device flashes and reboots mid-copy, so
///      the volume vanishing during/after the write is the success signal.
///   4. Wait for TINGDISK to come back, then re-run Flash EP so the tingle
///      payload rides the new firmware.
///
/// Why upgrade at all: fw <= 1.0.5 reloads factory samples after battery
/// sleep (silencing the chirp protocol); 1.0.6+ fixes it at the source.
public enum FirmwareUpgrader {
    /// Latest firmware verified against the tingle payload.
    public static let version = "1.0.8"
    private static let zipURL = URL(string: "https://teenage.engineering/_software/ep-2350/ep-2350_firmware_1_0_8.zip")!
    private static let zipSHA256 = "d616d4eb35d8f40b0c48fe6bc95f3156d720822fc3619a3d78e880c8b9d0cf18"
    private static let uf2Name = "ep-2350_firmware_1_0_8.uf2"

    private static let log = Logger(subsystem: Log.subsystem, category: "firmware")

    /// Rides on EVERY progress card in this flow. The ritual needs the
    /// handle held from before the boot disk appears until the flow says
    /// otherwise, and a bare step line left the user guessing whether it
    /// was safe to let go mid-upgrade (2026-08-05).
    public static let holdReminder =
        "KEEP THE TRIGGER HELD DOWN - DO NOT RELEASE UNTIL INSTRUCTED"

    public static func progressText(step: String) -> String {
        "\(holdReminder)\n\n\(step)"
    }

    enum UpgradeError: LocalizedError {
        case downloadFailed(String)
        case checksumMismatch
        case unzipFailed
        case bootloaderTimeout
        case tingdiskTimeout
        case wrongVariant(String)
        case alreadyNewer(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let detail):
                return "Firmware download failed: \(detail)"
            case .checksumMismatch:
                return "Firmware download did not match the expected checksum — not flashing it."
            case .unzipFailed:
                return "Could not extract the firmware from Teenage Engineering's zip."
            case .bootloaderTimeout:
                return "Never saw the TING BOOT disk. Two things trip people up: KEEP the handle squeezed the whole time, and the button needs a true DOUBLE-CLICK — two quick presses in rapid succession, like a mouse double-click (two deliberate separate presses just power-cycle it). Lid off, USB connected, squeeze and hold, double-click the small button above the USB port. Run the upgrade again to retry."
            case .tingdiskTimeout:
                return "Firmware was written, but TINGDISK didn't come back. Power-cycle the ting and run Flash EP from the menu."
            case .wrongVariant(let volume):
                return "\(volume) is an FX MIC bootloader, but tingle's pinned firmware \(version) is the ting build. Nothing was written. Release the handle and power-cycle the device."
            case .alreadyNewer(let running):
                return "This device already runs firmware \(running), newer than tingle's pinned \(version). Nothing was written."
            }
        }
    }

    /// Runs the whole upgrade off the main thread; `status` lands on the
    /// main queue (same contract as Flasher.run). Ends by re-running the
    /// payload flash so the event engine rides the new firmware.
    static func upgrade(
        frequencies: [Double],
        status: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let report: (String) -> Void = { text in DispatchQueue.main.async { status(text) } }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if let running = runningVersion(), isVersion(running, atLeast: version),
                   running != version {
                    throw UpgradeError.alreadyNewer(running)
                }

                report("Downloading firmware \(version)…")
                let uf2 = try fetchUF2()

                report("Waiting for the TING BOOT disk (keep squeezing the handle)…")
                let bootVolume = try waitForBootloaderVolume(timeout: 180)
                // TE ships separate ting and FX MIC builds since 1.1.x; the
                // pinned image predates the split and targets the ting.
                if bootVolume.lastPathComponent.uppercased().contains("FX MIC") {
                    throw UpgradeError.wrongVariant(bootVolume.lastPathComponent)
                }

                report("Writing firmware…")
                try writeUF2(uf2, to: bootVolume)

                report("Waiting for the ting to come back…")
                _ = try waitForTingdisk(timeout: 120)

                report("Reinstalling the tingle payload…")
                try Flasher.flashEP(frequencies: frequencies, progress: report)

                Prefs.setLastFlashedFirmware(version, serial: dockedSerial())
                log.info("firmware upgrade to \(version, privacy: .public) complete")
                DispatchQueue.main.async {
                    completion(.success("You can release the handle now.\n\nFirmware \(version) and the tingle event engine are on the ting."))
                }
            } catch {
                log.error("firmware upgrade failed: \(String(describing: error))")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Identity of the docked ting: the unique suffix of its CDC device
    /// path (e.g. /dev/cu.usbmodemEPTXP3R31 -> "EPTXP3R31"). Nil when no
    /// ting is enumerated over USB.
    static func dockedSerial() -> String? {
        DetectionCoordinator.findSerialDevicePath()
            .map { $0.replacingOccurrences(of: "/dev/cu.usbmodem", with: "") }
    }

    /// The CDC port is named after the USB serial number, which starts
    /// with "EP" but varies by product variant: the ting enumerates as
    /// cu.usbmodemEPTXP*, the FX MIC as cu.usbmodemEPXYW*.
    public static func serialDevicePath(among deviceNames: [String]) -> String? {
        deviceNames
            .filter { $0.hasPrefix("cu.usbmodemEP") }
            .sorted()
            .first
            .map { "/dev/\($0)" }
    }

    /// True when this device needs no firmware flow: tingle flashed the
    /// pinned version onto it, or it reports a version at least that new.
    /// Without the second check, Flash EP on an FX MIC shipping 1.1.2 would
    /// route through the ritual and DOWNGRADE it to the pinned 1.0.8.
    public static func isFirmwareCurrent() -> Bool {
        if Prefs.lastFlashedFirmware(serial: dockedSerial()) == version { return true }
        guard let running = runningVersion() else { return false }
        return isVersion(running, atLeast: version)
    }

    /// Firmware the docked device reports in its USB product name. Newer
    /// firmware embeds it ("EP_2350 1_1_2"); older builds only said
    /// "EP-2350", so nil means unknown, not old.
    public static func runningVersion() -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            let vendor = IORegistryEntryCreateCFProperty(
                service, "idVendor" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            guard vendor == teenageEngineeringVendorID else { continue }
            let name = IORegistryEntryCreateCFProperty(
                service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if let name, let parsed = firmwareVersion(fromProductName: name) { return parsed }
        }
        return nil
    }

    static let teenageEngineeringVendorID = 0x2367

    public static func firmwareVersion(fromProductName name: String) -> String? {
        let tokens = name.split(separator: " ")
        guard tokens.count >= 2, tokens[0].replacingOccurrences(of: "_", with: "-") == "EP-2350"
        else { return nil }
        let parts = tokens[1].split(whereSeparator: { $0 == "_" || $0 == "." })
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.joined(separator: ".")
    }

    public static func isVersion(_ a: String, atLeast b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return true
    }

    // MARK: - Steps

    private static func fetchUF2() throws -> Data {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tingle-fw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zipPath = work.appendingPathComponent("fw.zip")
        let zipData: Data
        do {
            zipData = try Data(contentsOf: zipURL)
        } catch {
            throw UpgradeError.downloadFailed(error.localizedDescription)
        }
        guard SHA256.hash(data: zipData).map({ String(format: "%02x", $0) }).joined() == zipSHA256 else {
            throw UpgradeError.checksumMismatch
        }
        try zipData.write(to: zipPath)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", zipPath.path, uf2Name, "-d", work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let uf2 = try? Data(contentsOf: work.appendingPathComponent(uf2Name)),
              !uf2.isEmpty
        else { throw UpgradeError.unzipFailed }
        return uf2
    }

    /// The ROM bootloader mounts as a small FAT volume whose marker file is
    /// INFO_UF2.TXT (named RP2350 in practice, but the marker is what's
    /// authoritative).
    private static func waitForBootloaderVolume(timeout: TimeInterval) throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let volumes = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []
            for volume in volumes
            where FileManager.default.fileExists(
                atPath: volume.appendingPathComponent("INFO_UF2.TXT").path) {
                log.info("bootloader volume: \(volume.path, privacy: .public)")
                return volume
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw UpgradeError.bootloaderTimeout
    }

    private static func writeUF2(_ uf2: Data, to volume: URL) throws {
        let target = volume.appendingPathComponent(uf2Name)
        do {
            try uf2.write(to: target)
        } catch {
            // The device reboots the instant the last block lands, yanking
            // the volume out from under the write — that's success, not
            // failure. Only a write error with the volume still present is
            // real.
            if FileManager.default.fileExists(atPath: volume.path) { throw error }
            log.info("bootloader volume vanished during write (device rebooting)")
        }
    }

    /// Waits for WRITABILITY, not mere presence: the volume reappears
    /// before the mount is usable, and the payload flash that follows was
    /// failing on "1.wav ... permission" (2026-08-05).
    private static func waitForTingdisk(timeout: TimeInterval) throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Flasher.isTingleiskWritable { return Flasher.volumeURL }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw UpgradeError.tingdiskTimeout
    }
}
