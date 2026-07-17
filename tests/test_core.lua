-- test_core.lua — plain `lua5.4 tests/test_core.lua`, no game required.
local failures = 0
local total = 0

local function eq(got, want, label)
    total = total + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
    end
end

local function loadModule(path)
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    local chunk = assert(load(text, "@" .. path))
    return chunk()
end

local core = loadModule("PalJobsPreferred/Scripts/core.lua")

eq(core.norm(-1), 0xFFFFFFFF, "norm negative")
eq(core.norm(5), 5, "norm positive")

local key = core.palKey(
    { A = 1, B = 2, C = 3, D = 4 },
    { A = 5, B = 6, C = 7, D = 8 })
eq(key,
    "00000001000000020000000300000004-00000005000000060000000700000008",
    "palKey formatting")

local key2 = core.palKey(
    { A = 1, B = 2, C = 3, D = 4 },
    { A = 5, B = 6, C = 7, D = 8 })
eq(key, key2, "palKey determinism")

eq(core.cycleStep(5, 1), 6, "cycleStep 5+1")
eq(core.cycleStep(5, -1), 4, "cycleStep 5-1")
eq(core.cycleStep(10, 1), 0, "cycleStep wraps at max")
eq(core.cycleStep(0, -1), 10, "cycleStep wraps at min")
eq(core.cycleStep(nil, 1), 1, "cycleStep nil current")

eq(core.clampPrio(7), 7, "clampPrio in range")
eq(core.clampPrio(-3), 0, "clampPrio below min")
eq(core.clampPrio(99), 10, "clampPrio above max")
eq(core.clampPrio(7.9), 7, "clampPrio floors fractional")
eq(core.clampPrio("nope"), 0, "clampPrio non-number")

eq(core.vanillaDefault(true), 5, "vanillaDefault on")
eq(core.vanillaDefault(false), 0, "vanillaDefault off")

eq(core.prioDisplayText(nil), "", "prioDisplayText nil")
eq(core.prioDisplayText(0), "X", "prioDisplayText zero")
eq(core.prioDisplayText(7), "7", "prioDisplayText positive")
eq(core.prioDisplayText(10), "10", "prioDisplayText double-digit")

local sampleText = [[
return {
  pals = {
    ["ABC-123"] = { name = "Testpal", prio = { [8]=5, [12]=2 },
      raw = { PlayerUId = { A=1,B=2,C=3,D=4 }, InstanceId = { A=5,B=6,C=7,D=8 } } },
  },
}
]]
local parsed, perr = core.parseConfig(sampleText)
eq(perr, nil, "parseConfig well-formed: no error")
eq(parsed ~= nil, true, "parseConfig well-formed: table returned")
if parsed then
    eq(parsed.pals["ABC-123"].name, "Testpal", "parseConfig well-formed: name")
    eq(parsed.pals["ABC-123"].prio[8], 5, "parseConfig well-formed: prio[8]")
    eq(parsed.pals["ABC-123"].prio[12], 2, "parseConfig well-formed: prio[12]")
end

local broken, berr = core.parseConfig("return { pals = { THIS IS NOT LUA")
eq(broken, nil, "parseConfig broken input: nil result")
eq(berr ~= nil, true, "parseConfig broken input: error message present")

local notTable, ntErr = core.parseConfig("return 42")
eq(notTable, nil, "parseConfig non-table: nil result")
eq(ntErr ~= nil, true, "parseConfig non-table: error message present")

local original = {
    pals = {
        ["KEY-1"] = {
            name = "Roundtrip",
            prio = { [3] = 4, [8] = 10 },
            raw = {
                PlayerUId = { A = 11, B = 22, C = 33, D = 44 },
                InstanceId = { A = 55, B = 66, C = 77, D = 88 },
            },
        },
    },
}
local serialized = core.serializeConfig(original)
local reparsed, rerr = core.parseConfig(serialized)
eq(rerr, nil, "serialize->parse round-trip: no error")
if reparsed then
    eq(reparsed.pals["KEY-1"].name, "Roundtrip", "round-trip: name preserved")
    eq(reparsed.pals["KEY-1"].prio[3], 4, "round-trip: prio[3] preserved")
    eq(reparsed.pals["KEY-1"].prio[8], 10, "round-trip: prio[8] preserved")
    eq(reparsed.pals["KEY-1"].raw.PlayerUId.A, 11, "round-trip: raw.PlayerUId.A preserved")
end

local tmpPath = os.tmpname()
local sok, serr = core.saveConfig(original, tmpPath)
eq(sok, true, "saveConfig: succeeds")
eq(serr, nil, "saveConfig: no error")
local loaded, lerr = core.loadConfig(tmpPath)
eq(lerr, nil, "loadConfig: no error")
if loaded then
    eq(loaded.pals["KEY-1"].prio[8], 10, "saveConfig->loadConfig: prio[8] preserved")
end
os.remove(tmpPath)

local missing, merr = core.loadConfig("/nonexistent/path/priorities.lua")
eq(missing, nil, "loadConfig missing file: nil result")
eq(merr ~= nil, true, "loadConfig missing file: error message present")

local resolved, found = core.resolveConfigPath()
eq(resolved, core.candidatePaths()[1], "resolveConfigPath falls back to first candidate")
eq(found, false, "resolveConfigPath: not found in test cwd")

print(string.format("%d/%d assertions passed", total - failures, total))
if failures > 0 then
    os.exit(1)
end
