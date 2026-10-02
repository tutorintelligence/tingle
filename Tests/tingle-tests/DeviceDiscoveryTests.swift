import Foundation
import TingleCore

func runDeviceDiscoveryTests() {
    // --- serial port: the FX MIC variant enumerates under a different
    // USB serial prefix than the ting and went undiscovered (2026-10-01) ---
    expectEqual(FirmwareUpgrader.serialDevicePath(among: ["cu.usbmodemEPTXP3R31"]),
                "/dev/cu.usbmodemEPTXP3R31", "discovery: ting serial port")
    expectEqual(FirmwareUpgrader.serialDevicePath(among: ["cu.usbmodemEPXYW1R31"]),
                "/dev/cu.usbmodemEPXYW1R31", "discovery: FX MIC serial port")
    expectEqual(FirmwareUpgrader.serialDevicePath(
                    among: ["cu.Bluetooth-Incoming-Port", "cu.usbmodem21201", "tty.usbmodemEPXYW1R31"]),
                nil, "discovery: other usbmodems and tty nodes ignored")

    // --- FAT disk: TINGDISK on the ting, "FX MIC DISK" on the FX MIC ---
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tingle-volumes-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    expect(Flasher.mountedVolume(in: root) == nil, "discovery: no device disk mounted")
    let fxMic = root.appendingPathComponent("FX MIC DISK", isDirectory: true)
    try? FileManager.default.createDirectory(at: fxMic, withIntermediateDirectories: true)
    expectEqual(Flasher.mountedVolume(in: root)?.lastPathComponent, "FX MIC DISK",
                "discovery: FX MIC DISK found")
    let ting = root.appendingPathComponent("TINGDISK", isDirectory: true)
    try? FileManager.default.createDirectory(at: ting, withIntermediateDirectories: true)
    expectEqual(Flasher.mountedVolume(in: root)?.lastPathComponent, "TINGDISK",
                "discovery: TINGDISK found")

    // --- running firmware from the USB product name: the guard that stops
    // Flash EP from downgrading a 1.1.2 FX MIC to the pinned 1.0.8 ---
    expectEqual(FirmwareUpgrader.firmwareVersion(fromProductName: "EP_2350 1_1_2"), "1.1.2",
                "firmware: USB product name parsed")
    expectEqual(FirmwareUpgrader.firmwareVersion(fromProductName: "EP-2350 1.1.2"), "1.1.2",
                "firmware: registry entry name parsed")
    expectEqual(FirmwareUpgrader.firmwareVersion(fromProductName: "EP-2350"), nil,
                "firmware: old builds report no version")
    expectEqual(FirmwareUpgrader.firmwareVersion(fromProductName: "TS5 Plus USB 2 Hub"), nil,
                "firmware: unrelated device ignored")
    expect(FirmwareUpgrader.isVersion("1.1.2", atLeast: "1.0.8"), "firmware: 1.1.2 >= 1.0.8")
    expect(FirmwareUpgrader.isVersion("1.0.10", atLeast: "1.0.8"), "firmware: numeric, not lexical")
    expect(FirmwareUpgrader.isVersion("1.0.8", atLeast: "1.0.8"), "firmware: equal counts as current")
    expect(!FirmwareUpgrader.isVersion("1.0.5", atLeast: "1.0.8"), "firmware: 1.0.5 is behind")
}
