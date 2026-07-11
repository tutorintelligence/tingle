import Foundation
import TingleCore

func runConfigTests() {
    do { // the shipped literate default template must parse to the defaults
        let config = try! TingConfig.parse(toml: ConfigStore.defaultTOML)
        expectEqual(config.toneFrequencies, [17500, 18000, 18500, 19000], "config: default frequencies")
        expect(config.vocabulary.count > 100, "config: generous default vocabulary")
        expect(config.vocabulary.contains("TOML"), "config: TOML never Tamil again")
        expect(config.vocabulary.contains("Claude"), "config: Claude in vocabulary")
        expect(config.vocabulary.contains("subagent"), "config: agentic terms present")
        expectEqual(Set(config.vocabulary), Set(ConfigStore.defaultVocabulary),
                    "config: TOML template and Swift default vocabulary stay in sync")
        expectEqual(config.mappings["triggerDown"], .dictate, "config: default trigger mapping")
        expectEqual(config.mappings["modeChange"], .eraseDictation, "config: default green mapping")
        expectEqual(config.mappings["fxChange"], .keystroke(key: "return", modifiers: []), "config: default orange mapping")
        expect(config.mappings["mode1"] == nil, "config: no per-mode white mappings by default")
        if case .shell(let cmd)? = config.mappings["white"] {
            expect(cmd.contains("open -a"), "config: white catch-all is the summon script")
        } else {
            expect(false, "config: white catch-all mapped by default")
        }
        expectEqual(config.action(for: .whitePress(mode: 3)), config.mappings["white"],
                    "config: whitePress falls back to the white catch-all")
    }
    do { // multiline embedded script + all action types
        let toml = """
        vocabulary = ["Cubilux"]

        [mappings]
        mode1 = { type = "shell", command = '''
        for app in "Claude" "Codex"; do
          open -a "$app" && exit 0
        done
        ''' }
        mode2 = { type = "keystroke", key = "escape", modifiers = ["cmd", "shift"] }
        triggerDown = { type = "keyHold", key = "f5" }
        """
        let config = try! TingConfig.parse(toml: toml)
        guard case .shell(let command)? = config.mappings["mode1"] else {
            expect(false, "config: multiline shell parses"); return
        }
        expect(command.contains("open -a \"$app\""), "config: multiline script content")
        expect(command.contains("\n"), "config: script is genuinely multiline")
        expectEqual(config.mappings["mode2"], .keystroke(key: "escape", modifiers: ["cmd", "shift"]),
                    "config: keystroke with modifiers")
        expectEqual(config.mappings["triggerDown"], .keyHold(key: "f5", modifiers: []),
                    "config: keyHold defaults empty modifiers")
        expectEqual(config.vocabulary, ["Cubilux"], "config: vocabulary list")
        expectEqual(config.toneFrequencies, [17500, 18000, 18500, 19000],
                    "config: omitted frequencies fall back to defaults")
    }
    do { // unknown action type is a hard parse error (typo safety)
        let bad = """
        [mappings]
        mode1 = { type = "keystorke", key = "a" }
        """
        expect((try? TingConfig.parse(toml: bad)) == nil, "config: unknown action type rejected")
    }
}

func runBatteryEstimateTests() {
    expectEqual(BatteryEstimate.percent(packVolts: 3.2), 100, "battery: fresh pack")
    expectEqual(BatteryEstimate.percent(packVolts: 1.9), 0, "battery: dead pack")
    expect(BatteryEstimate.percent(packVolts: 3.0) > 60, "battery: 1.5V/cell reads healthy")
    expect((20...60).contains(BatteryEstimate.percent(packVolts: 2.45)), "battery: mid-plateau plausible")
    // monotonic: more volts never reads as less charge
    var last = -1
    for mv in stride(from: 1800, through: 3300, by: 10) {
        let p = BatteryEstimate.percent(packVolts: Double(mv) / 1000)
        expect(p >= last, "battery: monotonic at \(mv)mV")
        last = p
    }
}

func runReplacementTests() {
    let map = ["Tamil": "TOML", "clod": "Claude"]
    expectEqual(TingConfig.applyReplacements("commit the Tamil file", map),
                "commit the TOML file", "replacements: basic word swap")
    expectEqual(TingConfig.applyReplacements("Tamil, Tamil!", map),
                "TOML, TOML!", "replacements: punctuation boundaries")
    expectEqual(TingConfig.applyReplacements("Tamilnadu is a state", map),
                "Tamilnadu is a state", "replacements: no partial-word hits")
    expectEqual(TingConfig.applyReplacements("ask clod about it", map),
                "ask Claude about it", "replacements: second rule")
    expectEqual(TingConfig.applyReplacements("nothing to do", [:]),
                "nothing to do", "replacements: empty map is identity")

    let config = try! TingConfig.parse(toml: ConfigStore.defaultTOML)
    expectEqual(config.replacements["Tamil"], "TOML", "config: default Tamil->TOML rule")
    expectEqual(config.replacements["clawed"], "Claude", "config: default clawed->Claude rule")
    expectEqual(TingConfig.applyReplacements("open clawed code", config.replacements),
                "open Claude code", "replacements: clawed corrected in context")
}


func runWhiteFallbackTests() {
    let toml = """
    [mappings]
    white = { type = "keystroke", key = "escape" }
    mode2 = { type = "keystroke", key = "space" }
    """
    let config = try! TingConfig.parse(toml: toml)
    expectEqual(config.action(for: .whitePress(mode: 2)), .keystroke(key: "space", modifiers: []),
                "white fallback: specific mode wins")
    expectEqual(config.action(for: .whitePress(mode: 1)), .keystroke(key: "escape", modifiers: []),
                "white fallback: catch-all covers unmapped modes")
    expectEqual(config.action(for: .modeChanged(mode: 1)), nil,
                "white fallback: catch-all never leaks to other events")
}
