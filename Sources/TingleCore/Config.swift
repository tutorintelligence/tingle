import Foundation
import TOMLKit
import os

/// A user-configured action fired when a ting event is detected.
public enum TingAction: Equatable {
    case keystroke(key: String, modifiers: [String])
    case shell(command: String)
    /// Posts key-DOWN only and keeps the key held; the matching key-UP is
    /// posted when triggerUp fires (or on quit). Meant for the triggerDown
    /// mapping — enables hold-to-dictate hotkeys.
    case keyHold(key: String, modifiers: [String])
    /// Native live dictation (SpeechAnalyzer, macOS 26): triggerDown starts
    /// transcribing the ting's mic and types into the frontmost app live;
    /// triggerUp finalizes. Valid ONLY on the triggerDown mapping.
    case dictate
    /// Erase the last completed dictation take (repeat presses peel back
    /// earlier takes). Default on the green button (modeChange).
    case eraseDictation

    /// Short human-readable description (menu display).
    public var summary: String {
        switch self {
        case .keystroke(let key, let modifiers):
            return "keystroke: " + (modifiers + [key]).joined(separator: "+")
        case .shell(let command):
            return "shell: \(command)"
        case .keyHold(let key, let modifiers):
            return "keyHold: " + (modifiers + [key]).joined(separator: "+")
        case .dictate:
            return "dictate (live transcription)"
        case .eraseDictation:
            return "erase last dictation"
        }
    }
}

extension TingAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, key, modifiers, command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "keystroke":
            self = .keystroke(
                key: try container.decode(String.self, forKey: .key),
                modifiers: try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
            )
        case "shell":
            self = .shell(command: try container.decode(String.self, forKey: .command))
        case "keyHold":
            self = .keyHold(
                key: try container.decode(String.self, forKey: .key),
                modifiers: try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
            )
        case "dictate":
            self = .dictate
        case "eraseDictation":
            self = .eraseDictation
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown action type \"\(type)\" (expected \"keystroke\", \"shell\", \"keyHold\", \"dictate\" or \"eraseDictation\")"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keystroke(let key, let modifiers):
            try container.encode("keystroke", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(modifiers, forKey: .modifiers)
        case .shell(let command):
            try container.encode("shell", forKey: .type)
            try container.encode(command, forKey: .command)
        case .keyHold(let key, let modifiers):
            try container.encode("keyHold", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(modifiers, forKey: .modifiers)
        case .dictate:
            try container.encode("dictate", forKey: .type)
        case .eraseDictation:
            try container.encode("eraseDictation", forKey: .type)
        }
    }
}

/// The user's configuration, parsed from literate TOML. TOML has no null,
/// so an unmapped input is simply an absent key; every field is optional
/// with sensible defaults.
/// Post-dictation LLM rewrite pass (Apple's on-device Foundation model).
/// Every bool maps to a fixed prompt fragment; `customInstructions` is the
/// only freeform field and is appended last. All inert unless `enabled`.
public struct RewriteConfig: Decodable, Equatable {
    public var enabled = false
    public var removeFillers = true
    public var fixPunctuation = true
    public var fixGrammar = false
    public var correctVocabulary = true
    public var technicalFormatting = false
    public var customInstructions = ""

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, removeFillers, fixPunctuation, fixGrammar,
             correctVocabulary, technicalFormatting, customInstructions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? true
        fixPunctuation = try c.decodeIfPresent(Bool.self, forKey: .fixPunctuation) ?? true
        fixGrammar = try c.decodeIfPresent(Bool.self, forKey: .fixGrammar) ?? false
        correctVocabulary = try c.decodeIfPresent(Bool.self, forKey: .correctVocabulary) ?? true
        technicalFormatting = try c.decodeIfPresent(Bool.self, forKey: .technicalFormatting) ?? false
        customInstructions = try c.decodeIfPresent(String.self, forKey: .customInstructions) ?? ""
    }
}

public struct TingConfig: Decodable {
    /// The four mode tone frequencies (Hz), in mode order 1–4.
    public var toneFrequencies: [Double]
    /// Words/phrases biasing dictation recognition (names, jargon) via
    /// AnalysisContext.contextualStrings. Cheap, applied per-session.
    public var vocabulary: [String]
    /// "mode1"…"mode4" (white per green mode), "modeChange" (green),
    /// "fxChange" (orange), "triggerDown"/"triggerUp" (handle).
    public var mappings: [String: TingAction]
    /// Post-recognition corrections applied to finalized transcript
    /// segments (word-boundary, case-sensitive). The escape hatch for
    /// words the recognizer's lexicon simply refuses to produce.
    public var replacements: [String: String]
    /// Post-dictation LLM rewrite pass.
    public var rewrite: RewriteConfig

    /// The default white-button action: bring the first running AI coding
    /// app to the front, ready to dictate into.
    static let summonAgentScript = """
for app in "Claude" "Codex" "Cursor" "iTerm2" "Terminal"; do
  if osascript -e 'application "'"$app"'" is running' 2>/dev/null | grep -q true; then
    osascript - "$app" <<'APPLESCRIPT'
on run argv
  set appName to item 1 of argv
  tell application appName to activate
  delay 0.3
  tell application "System Events" to tell process appName
    try
      set {wx, wy} to position of window 1
      set {ww, wh} to size of window 1
      click at {wx + (ww / 2), wy + (wh * 0.9)}
    end try
  end tell
end run
APPLESCRIPT
    exit 0
  fi
done
"""

    static let `default` = TingConfig(
        toneFrequencies: [17500, 18000, 18500, 19000],
        vocabulary: ConfigStore.defaultVocabulary,
        mappings: [
            // Ergonomic defaults: squeeze = dictate, orange = enter (submit),
            // green = scrap the last take. White is unmapped out of the box.
            "modeChange": .eraseDictation,
            "fxChange": .keystroke(key: "return", modifiers: []),
            "triggerDown": .dictate,
            "white": .shell(command: summonAgentScript),
        ],
        replacements: ["Tamil": "TOML", "clawed": "Claude", "Clawed": "Claude"]
    )

    init(toneFrequencies: [Double], vocabulary: [String],
         mappings: [String: TingAction], replacements: [String: String] = [:],
         rewrite: RewriteConfig = RewriteConfig()) {
        self.toneFrequencies = toneFrequencies
        self.vocabulary = vocabulary
        self.mappings = mappings
        self.replacements = replacements
        self.rewrite = rewrite
    }

    private enum CodingKeys: String, CodingKey {
        case toneFrequencies, vocabulary, mappings, replacements, rewrite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toneFrequencies = try container.decodeIfPresent([Double].self, forKey: .toneFrequencies)
            ?? Self.default.toneFrequencies
        vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        mappings = try container.decodeIfPresent([String: TingAction].self, forKey: .mappings) ?? [:]
        replacements = try container.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:]
        rewrite = try container.decodeIfPresent(RewriteConfig.self, forKey: .rewrite) ?? RewriteConfig()
    }

    /// Word-boundary, case-sensitive corrections for finalized transcript
    /// text. Longest keys win first so overlapping rules compose sanely.
    public static func applyReplacements(_ text: String, _ map: [String: String]) -> String {
        guard !map.isEmpty else { return text }
        var result = text
        for (key, value) in map.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: key) + "\\b"
            result = result.replacingOccurrences(of: pattern, with: value,
                                                 options: .regularExpression)
        }
        return result
    }

    /// Parse literate TOML (exposed for tests).
    public static func parse(toml: String) throws -> TingConfig {
        try TOMLDecoder().decode(TingConfig.self, from: toml)
    }

    public func action(forKey key: String) -> TingAction? {
        mappings[key]
    }

    public func action(for event: TingEvent) -> TingAction? {
        guard let key = event.mappingKey else { return nil }
        if let action = action(forKey: key) { return action }
        // "white" is a catch-all for white presses in any green mode, used
        // when the specific modeN key is unmapped.
        if case .whitePress = event { return action(forKey: "white") }
        return nil
    }
}

/// Menu-driven state that must NOT live in the user's hand-written TOML
/// (programmatic writes would destroy their comments): the pinned audio
/// input device. nil = automatic beacon discovery.
enum PinnedInput {
    private static let key = "audioInputDeviceUID"

    static var uid: String? {
        get { Prefs.suite.string(forKey: key) }
        set {
            if let newValue {
                Prefs.suite.set(newValue, forKey: key)
            } else {
                Prefs.suite.removeObject(forKey: key)
            }
        }
    }
}

/// Owns the on-disk config at ~/Library/Application Support/tingle/config.toml:
/// creates it with a literate default if missing, and live-reloads it on
/// change via a DispatchSource file watch (handles atomic saves too). The
/// file is user-authored only — tingle never writes to it after creation.
public final class ConfigStore {
    static let directoryURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tingle", isDirectory: true)
    static let configURL = directoryURL.appendingPathComponent("config.toml")
    static let legacyJSONURL = directoryURL.appendingPathComponent("config.json")

    /// The literate default config: the file IS the documentation.
    public static let defaultVocabulary: [String] = [
        "Claude",
        "Claude Code",
        "Codex",
        "tingle",
        "TOML",
        "JSON",
        "YAML",
        "GitHub",
        "git",
        "rebase",
        "repo",
        "monorepo",
        "changelog",
        "diff",
        "regex",
        "grep",
        "bash",
        "zsh",
        "shell",
        "sudo",
        "chmod",
        "ssh",
        "localhost",
        "DNS",
        "API",
        "CLI",
        "SDK",
        "IDE",
        "CI",
        "linter",
        "TypeScript",
        "JavaScript",
        "Python",
        "Swift",
        "SwiftPM",
        "Rust",
        "Xcode",
        "VS Code",
        "Cursor",
        "tmux",
        "Docker",
        "Kubernetes",
        "kubectl",
        "Postgres",
        "SQL",
        "SQLite",
        "Redis",
        "npm",
        "pip",
        "uv",
        "async",
        "await",
        "enum",
        "struct",
        "mutex",
        "goroutine",
        "lambda",
        "callback",
        "closure",
        "refactor",
        "backtrace",
        "stack trace",
        "segfault",
        "nil",
        "null",
        "boolean",
        "int",
        "float",
        "tuple",
        "dict",
        "hashmap",
        "iterator",
        "recursion",
        "memoize",
        "O of N",
        "big O",
        "endpoint",
        "webhook",
        "OAuth",
        "JWT",
        "TLS",
        "HTTPS",
        "gRPC",
        "protobuf",
        "WebSocket",
        "frontend",
        "backend",
        "middleware",
        "microservice",
        "Kafka",
        "cron",
        "daemon",
        "systemd",
        "launchd",
        "Homebrew",
        "cask",
        "notarize",
        "codesign",
        "entitlement",
        "TCC",
        "Tutor Intelligence",
        "teleop",
        "end effector",
        "gripper",
        "servo",
        "actuator",
        "encoder",
        "IMU",
        "lidar",
        "URDF",
        "ROS",
        "PLC",
        "kinematics",
        "inverse kinematics",
        "trajectory",
        "waypoint",
        "pick and place",
        "palletize",
        "conveyor",
        "workcell",
        "PCB",
        "firmware",
        "MicroPython",
        "RP2350",
        "UART",
        "GPIO",
        "I2C",
        "SPI",
        "ADC",
        "PWM",
        "oscilloscope",
        "solder",
        "Teenage Engineering",
        "Goertzel",
        "ultrasonic",
        "beacon",
        "chirp",
        "Cubilux",
        "line-in",
        "AAA battery",
        "power cycle",
        "subagent",
        "agentic",
        "LLM",
        "GPT",
        "Anthropic",
        "OpenAI",
        "Gemini",
        "prompt",
        "system prompt",
        "context window",
        "token",
        "tokenizer",
        "inference",
        "fine-tune",
        "RAG",
        "embedding",
        "vector database",
        "hallucination",
        "eval",
        "benchmark",
        "MCP",
        "tool call",
        "orchestration",
        "worktree",
        "sandbox",
        "headless",
        "transcript",
        "session",
        "hook",
        "slash command",
        "chain of thought",
        "depalletizing",
        "palletizing",
        "singulation",
        "kitting",
        "bin picking",
        "pick point",
        "cycle time",
        "throughput",
        "uptime",
        "downtime",
        "end-of-arm tooling",
        "EOAT",
        "suction cup",
        "vacuum gripper",
        "force-torque sensor",
        "tool center point",
        "flange",
        "wrist joint",
        "seventh axis",
        "gantry",
        "cobot",
        "stepper motor",
        "harmonic drive",
        "swerve drive",
        "infeed",
        "outfeed",
        "tote",
        "SKU",
        "carton",
        "slip sheet",
        "pallet jack",
        "light curtain",
        "area scanner",
        "e-stop",
        "interlock",
        "lockout tagout",
        "teach pendant",
        "homing",
        "joint limits",
        "joint space",
        "Cartesian",
        "quaternion",
        "rotation matrix",
        "kinematic chain",
        "forward kinematics",
        "singularity",
        "reachability",
        "motion planning",
        "collision checking",
        "payload",
        "calibration",
        "hand-eye calibration",
        "extrinsics",
        "intrinsics",
        "fiducial",
        "AprilTag",
        "ArUco",
        "point cloud",
        "depth camera",
        "UWB",
        "pose estimation",
        "bounding box",
        "segmentation",
        "YOLO",
        "ONNX",
        "TensorRT",
        "PyTorch",
        "quantization",
        "teleoperation",
        "provisioning",
        "commissioning",
        "site survey",
        "bootloader",
        "watchdog",
        "over-the-air update",
        "CAN bus",
        "CANopen",
        "Modbus",
        "EtherCAT",
        "RS-485",
        "HMI",
        "VFD",
        "PoE",
        "WireGuard",
        "WebRTC",
        "RTSP",
        "kustomize",
        "Terraform",
        "Dockerfile",
        "Grafana",
        "Prometheus",
        "ClickHouse",
        "alembic",
        "SQLAlchemy",
        "pytest",
        "mypy",
        "ruff",
        "Tutor",
        "README",
        "semver",
        "config",
    ]

    public static let defaultTOML = """
    # tingle configuration - this file is the documentation.
    # Edit and save: tingle reloads it live, no restart needed.
    #
    # -- The device ------------------------------------------------------------
    # Squeeze the ting's handle to dictate; release to finish.
    #   handle        -> "triggerDown" / "triggerUp"
    #   green button  -> "modeChange"   (also cycles the mode LED)
    #   orange button -> "fxChange"
    #   white button  -> "mode1".."mode4"  (which one depends on the mode LED)
    # Green and orange only register while the handle is released.
    #
    # -- Actions ------------------------------------------------------------
    #   { type = "dictate" }                     live transcription into the
    #                                            focused app (macOS 26+; only
    #                                            valid on triggerDown)
    #   { type = "eraseDictation" }              erase the last dictated take;
    #                                            press again for earlier takes
    #   { type = "keystroke", key = "return", modifiers = ["cmd"] }
    #   { type = "keyHold",   key = "f5" }       held until handle release
    #   { type = "shell",     command = "..." }  run with /bin/zsh -lc
    #
    # Keys: a-z, 0-9, f1-f12, return, escape, space, tab, delete, arrows.
    # Modifiers: "cmd", "shift", "opt", "ctrl".

    # Words and phrases that bias dictation recognition - names, jargon,
    # anything it keeps mishearing. Applied per-session, no training step.
    # Effective in the hundreds of entries (a giant dump dilutes the bias);
    # curate ruthlessly and add whatever it mangles for you.
    vocabulary = [
      "Claude", "Claude Code", "Codex", "tingle", "TOML",
      "JSON", "YAML", "GitHub", "git", "rebase",
      "repo", "monorepo", "changelog", "diff", "regex",
      "grep", "bash", "zsh", "shell", "sudo",
      "chmod", "ssh", "localhost", "DNS", "API",
      "CLI", "SDK", "IDE", "CI", "linter",
      "TypeScript", "JavaScript", "Python", "Swift", "SwiftPM",
      "Rust", "Xcode", "VS Code", "Cursor", "tmux",
      "Docker", "Kubernetes", "kubectl", "Postgres", "SQL",
      "SQLite", "Redis", "npm", "pip", "uv",
      "async", "await", "enum", "struct", "mutex",
      "goroutine", "lambda", "callback", "closure", "refactor",
      "backtrace", "stack trace", "segfault", "nil", "null",
      "boolean", "int", "float", "tuple", "dict",
      "hashmap", "iterator", "recursion", "memoize", "O of N",
      "big O", "endpoint", "webhook", "OAuth", "JWT",
      "TLS", "HTTPS", "gRPC", "protobuf", "WebSocket",
      "frontend", "backend", "middleware", "microservice", "Kafka",
      "cron", "daemon", "systemd", "launchd", "Homebrew",
      "cask", "notarize", "codesign", "entitlement", "TCC",
      "Tutor Intelligence", "teleop", "end effector", "gripper", "servo",
      "actuator", "encoder", "IMU", "lidar", "URDF",
      "ROS", "PLC", "kinematics", "inverse kinematics", "trajectory",
      "waypoint", "pick and place", "palletize", "conveyor", "workcell",
      "PCB", "firmware", "MicroPython", "RP2350", "UART",
      "GPIO", "I2C", "SPI", "ADC", "PWM",
      "oscilloscope", "solder", "Teenage Engineering", "Goertzel", "ultrasonic",
      "beacon", "chirp", "Cubilux", "line-in", "AAA battery",
      "power cycle",
      "subagent", "agentic", "LLM", "GPT", "Anthropic",
      "OpenAI", "Gemini", "prompt", "system prompt", "context window",
      "token", "tokenizer", "inference", "fine-tune", "RAG",
      "embedding", "vector database", "hallucination", "eval", "benchmark",
      "MCP", "tool call", "orchestration", "worktree", "sandbox",
      "headless", "transcript", "session", "hook", "slash command",
      "chain of thought",
      "depalletizing", "palletizing", "singulation", "kitting",
      "bin picking", "pick point", "cycle time", "throughput",
      "uptime", "downtime", "end-of-arm tooling", "EOAT",
      "suction cup", "vacuum gripper", "force-torque sensor", "tool center point",
      "flange", "wrist joint", "seventh axis", "gantry",
      "cobot", "stepper motor", "harmonic drive", "swerve drive",
      "infeed", "outfeed", "tote", "SKU",
      "carton", "slip sheet", "pallet jack", "light curtain",
      "area scanner", "e-stop", "interlock", "lockout tagout",
      "teach pendant", "homing", "joint limits", "joint space",
      "Cartesian", "quaternion", "rotation matrix", "kinematic chain",
      "forward kinematics", "singularity", "reachability", "motion planning",
      "collision checking", "payload", "calibration", "hand-eye calibration",
      "extrinsics", "intrinsics", "fiducial", "AprilTag",
      "ArUco", "point cloud", "depth camera", "UWB",
      "pose estimation", "bounding box", "segmentation", "YOLO",
      "ONNX", "TensorRT", "PyTorch", "quantization",
      "teleoperation", "provisioning", "commissioning", "site survey",
      "bootloader", "watchdog", "over-the-air update", "CAN bus",
      "CANopen", "Modbus", "EtherCAT", "RS-485",
      "HMI", "VFD", "PoE", "WireGuard",
      "WebRTC", "RTSP", "kustomize", "Terraform",
      "Dockerfile", "Grafana", "Prometheus", "ClickHouse",
      "alembic", "SQLAlchemy", "pytest", "mypy",
      "ruff",
      "Tutor",
      "README", "semver",
      "config",
    ]

    # Corrections applied to finalized dictation text (word-boundary,
    # case-sensitive) - for words the recognizer refuses to spell right
    # no matter how much vocabulary biasing it gets.
    [replacements]
    "Tamil" = "TOML"
    "REgex" = "regex"
    "GIT" = "git"
    "clawed" = "Claude"
    "Clawed" = "Claude"

    # After each take, an on-device language model (Apple Intelligence,
    # macOS 26+) can lightly clean the text in place: the take types
    # live as usual, then the polish lands a second later through the
    # same typing mechanics. Sending, erasing, a new squeeze, or
    # switching apps cancels a pending polish. Every switch below is a
    # fixed, tested instruction; customInstructions is freeform and is
    # applied last. Filler removal works even without Apple Intelligence.
    [rewrite]
    enabled = false
    removeFillers = true        # delete um/uh/er and the comma debris they leave
    fixPunctuation = true       # sentence boundaries, capitalization, run-ons
    fixGrammar = false          # light repair only; off because the model sometimes over-normalizes
    correctVocabulary = true    # let the model fix near-miss transcriptions of your vocabulary terms
    technicalFormatting = false # "dash dash force" -> "--force", "foo dot py" -> "foo.py"
    customInstructions = ""

    [mappings]
    # Squeeze to dictate into whatever app is focused.
    triggerDown = { type = "dictate" }

    # Orange: send it.
    fxChange = { type = "keystroke", key = "return" }

    # Green: scrap that take (press again for the take before it).
    modeChange = { type = "eraseDictation" }

    # White (any green mode): summon your agent - bring the first running
    # AI coding app to the front, ready to dictate into. Adjust the app
    # list to taste; "white" is a catch-all, or map mode1..mode4 for
    # per-mode actions.
    white = { type = "shell", command = '''
    for app in "Claude" "Codex" "Cursor" "iTerm2" "Terminal"; do
      if osascript -e 'application "'"$app"'" is running' 2>/dev/null | grep -q true; then
        osascript - "$app" <<'APPLESCRIPT'
    on run argv
      set appName to item 1 of argv
      tell application appName to activate
      delay 0.3
      tell application "System Events" to tell process appName
        try
          set {wx, wy} to position of window 1
          set {ww, wh} to size of window 1
          click at {wx + (ww / 2), wy + (wh * 0.9)}
        end try
      end tell
    end run
    APPLESCRIPT
        exit 0
      fi
    done
    ''' }
    """

    private(set) var config: TingConfig = .default

    private var observers: [() -> Void] = []
    private var watchSource: DispatchSourceFileSystemObject?
    private let log = Logger(subsystem: Log.subsystem, category: "config")

    init() {
        migrateLegacyDirectory()
        migrateLegacyJSON()
        ensureConfigFileExists()
        load()
        startWatching()
    }

    /// Register a callback fired (on the main queue) whenever the config reloads.
    func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    private func notifyObservers() {
        observers.forEach { $0() }
    }

    /// The pre-rename app dir was ~/Library/Application Support/tingd;
    /// carry the whole thing (config, backups) across once.
    private func migrateLegacyDirectory() {
        let fm = FileManager.default
        let old = Self.directoryURL.deletingLastPathComponent().appendingPathComponent("tingd")
        guard fm.fileExists(atPath: old.path),
              !fm.fileExists(atPath: Self.directoryURL.path) else { return }
        try? fm.moveItem(at: old, to: Self.directoryURL)
        log.info("migrated legacy tingd directory to tingle")
    }

    /// Pre-TOML installs used config.json; retire it visibly (renamed to
    /// .bak) rather than leaving a dead file that looks authoritative.
    private func migrateLegacyJSON() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.legacyJSONURL.path),
              !fm.fileExists(atPath: Self.configURL.path) else { return }
        try? fm.moveItem(at: Self.legacyJSONURL,
                         to: Self.legacyJSONURL.appendingPathExtension("bak"))
        log.info("legacy config.json retired to config.json.bak; writing default config.toml")
    }

    private func ensureConfigFileExists() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: Self.configURL.path) {
                try Self.defaultTOML.write(to: Self.configURL, atomically: true, encoding: .utf8)
                log.info("created default config at \(Self.configURL.path, privacy: .public)")
            }
        } catch {
            log.error("failed to create default config: \(String(describing: error))")
        }
    }

    private func load() {
        do {
            let text = try String(contentsOf: Self.configURL, encoding: .utf8)
            config = try TingConfig.parse(toml: text)
            log.info("config loaded")
        } catch {
            log.error("failed to load config (keeping previous): \(String(describing: error))")
        }
    }

    private func startWatching() {
        stopWatching()

        let fd = open(Self.configURL.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("cannot open config file for watching")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.watchSource else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Atomic save (or deletion): re-open the path after a beat.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self else { return }
                    self.ensureConfigFileExists()
                    self.load()
                    self.startWatching()   // re-arm on the new inode
                    self.notifyObservers()
                }
            } else {
                self.load()
                self.notifyObservers()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        watchSource = source
    }

    private func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    deinit {
        stopWatching()
    }
}
