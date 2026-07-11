import Darwin
import Foundation
import os

/// Passive line reader for the ting's USB CDC device using plain POSIX I/O
/// (no external dependencies).
///
/// A flashed device (FLASH EP ships device/tingle_main.py as /fat/main.py)
/// proactively prints event lines — no REPL grab, no Ctrl+C, no injection;
/// the running program is never interrupted:
///
///   "EVT white_down <sam_pos> <fx_pos>"
///   "EVT white_up <sam_pos> <fx_pos>"
///   "EVT mode <sam_pos>"          (green-button mode change)
///   "EVT fx <fx_pos>"             (orange-button FX change)
///   "EVT trigger_down"            (handle squeezed; device mic live)
///   "EVT erase"                   (3 rapid squeezes = erase gesture)
///   "EVT trigger_up"              (handle released)
///
/// Battery: the device REPL is idle between callback events, so we write
/// "print('VBAT',ui.get_vbat())\r" every 30s and parse the "VBAT <float>"
/// response (tolerating the command echo).
///
/// IMPORTANT: never send Ctrl+D (0x04, soft reset) — it re-enumerates USB and
/// a battery-less unit stays down until the power-button + handle ritual
/// (DESIGN.md). On stop/disconnect we just close the port.
final class SerialBackend: TingBackend {
    var onEvent: ((TingEvent) -> Void)?
    /// Battery voltage (volts), delivered on the main queue every ~30s.
    var onBattery: ((Double) -> Void)?
    /// Fired once (main queue) when the port fails or the device goes away.
    var onDisconnect: (() -> Void)?

    private(set) var isRunning = false
    /// True once a state-bearing beacon line ("EVT beacon 0|1") has been
    /// seen on this connection: released-beacons may then drive trigger-
    /// state healing (legacy stateless payloads must not).
    private(set) var payloadSendsBeaconState = false

    private let path: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "tingle.serial")
    private var readSource: DispatchSourceRead?
    private var batteryTimer: DispatchSourceTimer?
    private var lineBuffer = Data()
    private var didFail = false
    private let log = Logger(subsystem: Log.subsystem, category: "serial")

    private static let batteryInterval: TimeInterval = 30
    private static let maxLineBytes = 4096

    init(path: String) {
        self.path = path
    }

    func start() {
        queue.async { self.openAndBegin() }
    }

    func stop() {
        queue.async {
            self.teardown()
            self.isRunning = false
        }
    }

    // MARK: - Port setup

    private func openAndBegin() {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            log.error("open(\(self.path, privacy: .public)) failed: errno \(errno)")
            fail()
            return
        }

        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else {
            log.error("tcgetattr failed: errno \(errno)")
            fail()
            return
        }
        cfmakeraw(&tty)
        cfsetspeed(&tty, speed_t(B115200))
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &tty) == 0 else {
            log.error("tcsetattr failed: errno \(errno)")
            fail()
            return
        }

        // Purely passive from here: read whatever the flashed main.py prints.
        // Do NOT send Ctrl+C (would drop into the REPL and stall the event
        // engine) and NEVER Ctrl+D (see class comment).
        isRunning = true
        log.info("serial backend reading \(self.path, privacy: .public)")

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source

        // Battery request: once shortly after connect, then every 30s.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: Self.batteryInterval)
        timer.setEventHandler { [weak self] in self?.requestBattery() }
        timer.resume()
        batteryTimer = timer
    }

    // MARK: - Reading

    private func readAvailable() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                lineBuffer.append(contentsOf: buffer[0..<n])
                processLines()
                if n < buffer.count { return }
            } else if n == 0 {
                // EOF: device detached.
                fail()
                return
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                log.error("serial read failed: errno \(errno)")
                fail()
                return
            }
        }
    }

    private func processLines() {
        while let newlineIndex = lineBuffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineIndex)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8) {
                handleLine(line)
            }
        }
        // Defensive: drop a pathological unterminated line.
        if lineBuffer.count > Self.maxLineBytes {
            lineBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func handleLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }

        // Echo of our own battery command (the idle REPL echoes what we write).
        if line.contains("print(") { return }

        // Lines may interleave with other device output; match by prefix
        // anywhere in the line (e.g. a stray prompt before "EVT ...").
        if let range = line.range(of: "EVT ") {
            parseEvent(String(line[range.upperBound...]))
        } else if let range = line.range(of: "VBAT") {
            let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if let volts = Double(rest) {
                log.debug("battery: \(volts) V")
                DispatchQueue.main.async { self.onBattery?(volts) }
            }
        }
    }

    /// Parse the body after "EVT " defensively; ignore anything malformed.
    private func parseEvent(_ body: String) {
        let tokens = body.split(separator: " ")
        guard let kind = tokens.first else { return }

        func mode(fromToken index: Int) -> Int? {
            guard tokens.count > index, let samPos = Int(tokens[index]) else { return nil }
            return min(max(samPos, 0), 3) + 1
        }

        let event: TingEvent?
        switch kind {
        case "white_down":
            event = mode(fromToken: 1).map { TingEvent.whitePress(mode: $0) }
        case "white_up":
            event = mode(fromToken: 1).map { TingEvent.whiteRelease(mode: $0) }
        case "mode":
            event = mode(fromToken: 1).map { TingEvent.modeChanged(mode: $0) }
        case "fx":
            guard tokens.count > 1, let fxPos = Int(tokens[1]) else { return }
            event = .fxChanged(preset: fxPos)
        case "trigger_down":
            event = .triggerDown
        case "trigger_up":
            event = .triggerUp
        case "beacon":
            // Stateful payloads append handle state ("EVT beacon 0|1");
            // legacy payloads send no token — still a liveness signal, but
            // it must never be read as "released".
            if tokens.count > 1 {
                payloadSendsBeaconState = true
                event = tokens[1] == "1" ? .beaconHeld : .beacon
            } else {
                event = .beacon
            }
        case "erase":
            event = .eraseGesture
        default:
            event = nil
        }

        guard let event else {
            log.debug("ignoring unrecognized EVT line: \(body, privacy: .public)")
            return
        }
        if event == .beacon {
            log.debug("serial event: beacon")   // every ~2s; keep info logs quiet
        } else {
            log.info("serial event: \(event.logDescription, privacy: .public)")
        }
        DispatchQueue.main.async { self.onEvent?(event) }
    }

    // MARK: - Battery request

    private func requestBattery() {
        guard fd >= 0 else { return }
        if !writeBytes("print('VBAT',ui.get_vbat())\r") {
            fail()
        }
    }

    @discardableResult
    private func writeBytes(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        var written = 0
        var retries = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { pointer -> Int in
                write(fd, pointer.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if n > 0 {
                written += n
            } else if errno == EAGAIN && retries < 50 {
                retries += 1
                usleep(1000)
            } else {
                log.error("serial write failed: errno \(errno)")
                return false
            }
        }
        return true
    }

    // MARK: - Teardown

    /// Cancel sources and close the port. Just close: never soft-reset
    /// (Ctrl+D re-enumerates USB; see DESIGN.md). Runs on `queue`.
    private func teardown() {
        readSource?.cancel()
        readSource = nil
        batteryTimer?.cancel()
        batteryTimer = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func fail() {
        guard !didFail else { return }
        didFail = true
        teardown()
        isRunning = false
        DispatchQueue.main.async { self.onDisconnect?() }
    }
}
