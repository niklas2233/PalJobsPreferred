# PalJobsPreferred Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `PalPriority` + `PalPriorityUI` UE4SS Lua mod pair with a **single** `PalJobsPreferred` mod that works correctly whether installed on a dedicated server, a connecting client, or a singleplayer/listen-server host — self-detecting its role at runtime, with no separate client/server packages to install.

**Architecture:** One UE4SS Lua mod, split into a pure-logic `core.lua` (no UE4SS API, standalone-testable with a plain Lua interpreter) and a single `main.lua` entry point. `main.lua` detects at startup whether this process has game authority (`KismetSystemLibrary::IsServer()` — true for a dedicated server *and* a listen-server/singleplayer host, false for a pure connecting client) and gates the priority-decision logic on that check, while the display/click-sending logic runs unconditionally (naturally inert with no local player UI to attach to, which a dedicated server never has). Cross-machine communication piggybacks on two existing Palworld network RPCs — `Request_Server_int32` (client→server, already proven) and a second RPC to be identified via a research phase (server→client) — since UE4SS's Lua sandbox has no sockets/HTTP of its own.

**Tech Stack:** UE4SS 3.0.1 Beta (Okaetsu RE-UE4SS fork), Lua (UE4SS's bundled runtime, roughly Lua 5.1-compatible with LuaJIT-style extensions), Docker/docker-compose for the dedicated server host, plain `lua5.4` CLI on the dev host for standalone unit tests (no game required).

## Global Constraints

- **One mod, one folder, self-detecting role.** No separate client/server packages. Install the same `PalJobsPreferred` folder everywhere — dedicated server, singleplayer, or a connecting client's own game.
- Priority scale is **0–10** (not the original's 0–5); vanilla/unmodded client toggles map to **on → 5, off → 0**.
- No external processes, sidecar servers, or companion apps — everything ships as one drop-in UE4SS mod folder.
- The **live dedicated server** (container `palworld-wine-server`, compose stack at `/mnt/config/portainer/compose/66/`, currently serving 2 players across 3 bases) must not be used for any research/discovery work that carries crash risk. All discovery happens on a disposable throwaway server stood up specifically for this (Task 4), torn down when done.
- Config file (`priorities.lua`) stays a Lua table parsed via `load()`, not JSON. It is written only by whichever process has authority (`IsServer() == true`); a pure client never writes it.
- Left-click = +1 priority (cycle), right-click = -1, wrapping 0↔10. A new `PrioMod_SetPrio` command additionally allows setting an exact value in one call.
- Pal identity key format (`palKey`) is computed identically everywhere since it's now one shared `core.lua`: `norm(v) = v % 0x100000000`, key = 8 hex-padded uint32 fields joined as `"%08X%08X%08X%08X-%08X%08X%08X%08X"` (PlayerUId A-D, then InstanceId A-D).
- **A player connecting to any server that doesn't have this mod installed sees plain vanilla behavior** — the mod's client-side messages go unanswered (a legitimate, pre-existing engine RPC nothing is listening on for our custom tag), nothing is ever configured to display, so it's inert by construction. No special "detect and disable" logic is needed beyond this natural fallback.

---

## File Structure

```
/home/niklas/PalJobsPreferred/
  PalJobsPreferred/                     # the one mod — install everywhere
    enabled.txt
    Scripts/
      core.lua                          # pure logic, no UE4SS API
      main.lua                          # UE4SS hooks, role-detected via IsServer()
  tests/
    test_core.lua                       # standalone test script, plain `lua5.4 tests/test_core.lua`
  research-server/
    docker-compose.yml                  # disposable throwaway dedicated server
    stack.env
    FINDINGS.md                         # live-discovery notes (Task 6)
  docs/superpowers/
    specs/2026-07-17-paljobspreferred-design.md   # design doc (superseded on the single-mod point — see note below)
    plans/2026-07-17-paljobspreferred.md          # this file
```

**Note on the design doc:** the committed design doc still describes a
two-mod split (`PalJobsPreferred` + `PalJobsPreferredUI`). This plan
supersedes that specific point per a later correction — there was never a
real requirement for two packages, and a single self-detecting mod is
simpler to install and maintain. Everything else in the design doc (0–10
scale, vanilla fallback defaults, piggybacked RPC channels, disposable
research server) still applies. Update the design doc's architecture
section to match once this plan is approved, so the two documents don't
disagree.

**Why `core.lua` is split out:** UE4SS mods must run inside the live game,
which makes anything touching `RegisterHook`/`FindAllOf`/etc. untestable
outside a running server. Everything that doesn't need those APIs (pal-key
formatting, priority cycling math, config parse/serialize, vanilla-default
mapping) lives in `core.lua` instead, which is plain Lua with only
`io`/`os`/`string`/`table`/`math` — loadable and testable with a bare
`lua5.4` interpreter, no game required. `main.lua` loads it via `io.open` +
`load()` (not `require`/`dofile`) because `io.open` on a
`Mods/<ModName>/...`-relative path is a mechanism already proven to work in
this exact UE4SS build (used throughout the original mods' config loading);
`require`'s semantics in UE4SS's sandbox are untested, so this avoids
relying on an unverified assumption.

**Role detection — flagged as needing live verification, not yet
confirmed:** the plan below uses `KismetSystemLibrary::IsServer()`, called
via the same `StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")`
pattern already proven for `KismetTextLibrary` in the original code. This is
a standard, stable, non-Palworld-specific Unreal Engine function, so it's a
reasonable bet — but it has not been tested live in this UE4SS build the
way `Conv_StringToText` has. Task 5's first verification step confirms it
returns the expected value in each of the three roles (dedicated server /
listen-server host / pure client) before anything else is built on top of
it. If it doesn't behave as expected, Task 5 documents what was tried and
falls back to an alternative signal (documented inline in that task).

---

## Task 1: Project scaffolding + test tooling

**Files:**
- Create: `/home/niklas/PalJobsPreferred/PalJobsPreferred/enabled.txt`
- Create: `/home/niklas/PalJobsPreferred/.gitignore`

**Interfaces:** None yet — pure scaffolding.

- [ ] **Step 1: Install a standalone Lua interpreter for testing**

```bash
sudo apt-get update && sudo apt-get install -y lua5.4
```

Verify:

```bash
lua5.4 -v
```

Expected: a `Lua 5.4.x` version banner.

- [ ] **Step 2: Create the mod-enable marker file**

```bash
touch /home/niklas/PalJobsPreferred/PalJobsPreferred/enabled.txt
```

- [ ] **Step 3: Add a .gitignore**

Write `/home/niklas/PalJobsPreferred/.gitignore`:

```
*.tmp
research-server/palworld-data/
```

- [ ] **Step 4: Commit**

```bash
cd /home/niklas/PalJobsPreferred
git add PalJobsPreferred/enabled.txt .gitignore
git commit -m "Scaffold single-mod directory and enable marker"
```

---

## Task 2: core.lua (pure logic, shared by all roles) + standalone tests

**Files:**
- Create: `/home/niklas/PalJobsPreferred/PalJobsPreferred/Scripts/core.lua`
- Create: `/home/niklas/PalJobsPreferred/tests/test_core.lua`

**Interfaces:**
- Produces (consumed by Task 3's `main.lua` and by the test script):
  - `M.PRIO_MIN` (`0`), `M.PRIO_MAX` (`10`), `M.WORK_MIN` (`1`), `M.WORK_MAX` (`13`)
  - `M.norm(v: number) -> number`
  - `M.palKey(playerUId: {A,B,C,D}, instanceId: {A,B,C,D}) -> string`
  - `M.cycleStep(current: number|nil, dir: number) -> number` — wraps 0..10
  - `M.clampPrio(v: any) -> number` — clamps/coerces to a valid 0..10 integer
  - `M.vanillaDefault(isOn: boolean) -> number` — `5` if true, `0` if false
  - `M.candidatePaths() -> table` (array of string paths)
  - `M.resolveConfigPath() -> (path: string, foundOnDisk: boolean)`
  - `M.parseConfig(text: string) -> (config: table|nil, err: string|nil)`
  - `M.loadConfig(path: string) -> (config: table|nil, err: string|nil)`
  - `M.serializeConfig(config: table) -> string`
  - `M.saveConfig(config: table, path: string) -> (ok: boolean, err: string|nil)`
  - `M.prioDisplayText(prio: number|nil) -> string` — `""` for nil, `"X"` for `<=0`, else `tostring(prio)`

- [ ] **Step 1: Write `core.lua`**

```lua
-- core.lua — pure logic for PalJobsPreferred, shared by every role (server,
-- client, singleplayer). No UE4SS API calls anywhere in this file: only
-- io/os/string/table/math, so it loads and runs under a plain `lua5.4`
-- interpreter for standalone testing.
local M = {}

M.PRIO_MIN = 0
M.PRIO_MAX = 10
M.WORK_MIN = 1
M.WORK_MAX = 13

-- FGuid int32 fields come back sign-extended from UE4SS; mask to unsigned
-- 32-bit so the same pal always produces the same key regardless of sign.
function M.norm(v)
    return v % 0x100000000
end

function M.palKey(playerUId, instanceId)
    return string.format("%08X%08X%08X%08X-%08X%08X%08X%08X",
        M.norm(playerUId.A), M.norm(playerUId.B), M.norm(playerUId.C), M.norm(playerUId.D),
        M.norm(instanceId.A), M.norm(instanceId.B), M.norm(instanceId.C), M.norm(instanceId.D))
end

-- Cycle a priority value by `dir` (+1 or -1), wrapping 0..PRIO_MAX.
function M.cycleStep(current, dir)
    local v = (current or 0) + dir
    if v > M.PRIO_MAX then v = M.PRIO_MIN end
    if v < M.PRIO_MIN then v = M.PRIO_MAX end
    return v
end

-- Clamp/coerce an arbitrary requested value into a valid integer priority.
function M.clampPrio(v)
    if type(v) ~= "number" then return M.PRIO_MIN end
    if v < M.PRIO_MIN then return M.PRIO_MIN end
    if v > M.PRIO_MAX then return M.PRIO_MAX end
    return math.floor(v)
end

-- Vanilla (unmodded) client toggle default: on -> midpoint, off -> 0.
function M.vanillaDefault(isOn)
    return isOn and 5 or 0
end

function M.candidatePaths()
    return {
        "Mods/PalJobsPreferred/priorities.lua",
        "ue4ss/Mods/PalJobsPreferred/priorities.lua",
        "priorities.lua",
    }
end

-- Returns (path, foundOnDisk).
function M.resolveConfigPath()
    for _, p in ipairs(M.candidatePaths()) do
        local f = io.open(p, "r")
        if f then
            f:close()
            return p, true
        end
    end
    return M.candidatePaths()[1], false
end

-- Parse a priorities.lua file's content string. Returns (table) or (nil, err).
function M.parseConfig(text)
    local chunk, perr = load(text, "@priorities.lua")
    if not chunk then return nil, "parse error: " .. tostring(perr) end
    local ok, result = pcall(chunk)
    if not ok then return nil, "exec error: " .. tostring(result) end
    if type(result) ~= "table" then return nil, "config did not return a table" end
    if type(result.pals) ~= "table" then result.pals = {} end
    for k, e in pairs(result.pals) do
        if type(e) ~= "table" then
            result.pals[k] = nil
        else
            if type(e.prio) ~= "table" then e.prio = {} end
        end
    end
    return result
end

-- Load config from disk. Returns (table) or (nil, err).
function M.loadConfig(path)
    local f = io.open(path, "r")
    if not f then return nil, "cannot open " .. path end
    local text = f:read("*a")
    f:close()
    return M.parseConfig(text)
end

-- Serialize a config table to the priorities.lua text format.
function M.serializeConfig(config)
    local lines = { "return {", "  pals = {" }
    for key, entry in pairs(config.pals or {}) do
        local prioParts = {}
        for t = M.WORK_MIN, M.WORK_MAX do
            local p = entry.prio and entry.prio[t]
            if p and p ~= 0 then
                prioParts[#prioParts + 1] = string.format("[%d]=%d", t, p)
            end
        end
        local raw = entry.raw or {}
        local pu = raw.PlayerUId or { A = 0, B = 0, C = 0, D = 0 }
        local iid = raw.InstanceId or { A = 0, B = 0, C = 0, D = 0 }
        lines[#lines + 1] = string.format(
            '    ["%s"] = { name = %q, prio = { %s }, raw = { PlayerUId = { A=%d, B=%d, C=%d, D=%d }, InstanceId = { A=%d, B=%d, C=%d, D=%d } } },',
            key, entry.name or "", table.concat(prioParts, ", "),
            pu.A, pu.B, pu.C, pu.D, iid.A, iid.B, iid.C, iid.D)
    end
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

-- Write-to-temp-then-overwrite so a mid-write crash never leaves a truncated
-- file behind for the next read to choke on.
function M.saveConfig(config, path)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false, "cannot open " .. tmp .. " for write" end
    f:write(M.serializeConfig(config))
    f:close()
    local sf = io.open(tmp, "r")
    local text = sf:read("*a")
    sf:close()
    local df = io.open(path, "w")
    if not df then return false, "cannot open " .. path .. " for write" end
    df:write(text)
    df:close()
    os.remove(tmp)
    return true
end

-- Display text for a priority cell: "" for unconfigured, "X" for 0, else the number.
function M.prioDisplayText(prio)
    if prio == nil then return "" end
    if prio <= 0 then return "X" end
    return tostring(prio)
end

return M
```

- [ ] **Step 2: Write the standalone test script**

```lua
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
```

- [ ] **Step 3: Run the test to verify it passes**

```bash
cd /home/niklas/PalJobsPreferred
lua5.4 tests/test_core.lua
```

Expected: `42/42 assertions passed`, zero `FAIL` lines.

- [ ] **Step 4: Commit**

```bash
cd /home/niklas/PalJobsPreferred
git add PalJobsPreferred/Scripts/core.lua tests/test_core.lua
git commit -m "Add shared core.lua (pure priority/config logic) with standalone tests"
```

---

## Task 3: main.lua — role-detected hooks (server logic + client render/click-send in one file)

**Files:**
- Create: `/home/niklas/PalJobsPreferred/PalJobsPreferred/Scripts/main.lua`

**Interfaces:**
- Consumes: `core.lua`'s full interface (Task 2).
- Produces: the wire protocol other installs of this same mod rely on —
  `PrioMod_Ping`, `PrioMod_Dir` (`1`/`-1`), `PrioMod_SetPrio`
  (`workType * 100 + clampedPrio`) sent over `Request_Server_int32`.

- [ ] **Step 1: Write `main.lua`**

```lua
-- main.lua — PalJobsPreferred. One mod, every role. Priority-decision logic
-- only ACTS when IsServer() is true (dedicated server or listen-server/
-- singleplayer host); the render/click-sending logic runs unconditionally
-- and is naturally inert without a local player UI (never present on a
-- dedicated server).
local VERSION = "1.0.0"

local function log(msg)
    print(string.format("[PalJobsPreferred] %s\n", msg))
end

local logged = {}
local function logOnce(tag, msg)
    if logged[tag] then return end
    logged[tag] = true
    log(msg)
end

log(string.format("v%s loading...", VERSION))

-- ---------------------------------------------------------------------------
-- Load core.lua via io.open+load (see plan's File Structure section for why
-- not require/dofile).
-- ---------------------------------------------------------------------------
local core
do
    local candidates = {
        "Mods/PalJobsPreferred/Scripts/core.lua",
        "ue4ss/Mods/PalJobsPreferred/Scripts/core.lua",
    }
    for _, p in ipairs(candidates) do
        local f = io.open(p, "r")
        if f then
            local text = f:read("*a")
            f:close()
            local chunk, cerr = load(text, "@core.lua")
            if chunk then
                core = chunk()
                log("core.lua loaded from " .. p)
                break
            else
                log("core.lua found at " .. p .. " but failed to parse: " .. tostring(cerr))
            end
        end
    end
    if not core then
        error("PalJobsPreferred: could not load core.lua from any candidate path — mod cannot start")
    end
end

-- ---------------------------------------------------------------------------
-- Role detection. FLAGGED FOR LIVE VERIFICATION — see Task 5 Step 1. This is
-- the first thing checked when this mod is deployed anywhere, before
-- anything else in this file is trusted.
-- ---------------------------------------------------------------------------
local isServer = false
do
    local sysLib = nil
    pcall(function() sysLib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
    if sysLib then
        local ok = pcall(function() isServer = sysLib:IsServer() end)
        if not ok then
            log("IsServer() call failed — see Task 5 Step 1 fallback")
        end
    else
        log("KismetSystemLibrary not found — see Task 5 Step 1 fallback")
    end
end
log("role: " .. (isServer and "server-authoritative" or "client-only"))

-- ---------------------------------------------------------------------------
-- Config state (server-authoritative role only writes; every role can read
-- what's on disk, though only the authoritative role's copy is meaningful).
-- ---------------------------------------------------------------------------
local CONFIG_PATH = core.resolveConfigPath()
local config = { pals = {} }

if isServer then
    local cfg, lerr = core.loadConfig(CONFIG_PATH)
    if cfg then
        config = cfg
        local n = 0
        for _ in pairs(config.pals) do n = n + 1 end
        log(string.format("config loaded: %d pal(s) configured", n))
    else
        log("config load failed (" .. tostring(lerr) .. ") — starting with empty config")
    end
end

local function persist()
    if not isServer then return end
    local ok, err = core.saveConfig(config, CONFIG_PATH)
    if not ok then logOnce("save", "config save failed: " .. tostring(err)) end
end

-- ===========================================================================
-- SERVER-AUTHORITATIVE LOGIC — bodies below only act when isServer is true.
-- ===========================================================================

local moddedComps = {}
local pendingDirByComp = {}
local pendingSetPrioByComp = {}

local function findPalByKey(key)
    local dirs = nil
    local ok = pcall(function() dirs = FindAllOf("PalBaseCampWorkerDirector") end)
    if not ok or not dirs then return nil end
    for _, dir in ipairs(dirs) do
        local slots = nil
        pcall(function() slots = dir.CharacterHandleList end)
        if slots then
            local n = 0
            pcall(function() n = slots:GetArrayNum() end)
            for i = 0, (n or 0) - 1 do
                local handle = nil
                pcall(function() handle = slots[i] end)
                if handle then
                    local id, param = nil, nil
                    pcall(function() id = handle:GetIndividualID() end)
                    pcall(function() param = handle:GetWorkSuitabilityParam() end)
                    if id then
                        local okk, k = pcall(function() return core.palKey(id.PlayerUId, id.InstanceId) end)
                        if okk and k == key then return id, param end
                    end
                end
            end
        end
    end
    return nil
end

local internalCall = false
local campComp = nil

local function sendToggle(raw, workType, wantOn)
    if not campComp then return end
    internalCall = true
    pcall(function()
        campComp:RequestChangeWorkSuitability_ToServer(
            { PlayerUId = raw.PlayerUId, InstanceId = raw.InstanceId, DebugName = "" },
            workType, wantOn)
    end)
    internalCall = false
end

-- (A) Pending-work intake — server role only; harmless no-op elsewhere since
-- the hook body below checks isServer before doing anything.
local pending = {}

local okA, errA = pcall(function()
    RegisterHook("/Script/Pal.PalBaseCampWorkerDirector:OnRequiredAssignWork_ServerInternal",
        function(Context, Work, RequirementParameter)
            if not isServer then return end
            local ok, err = pcall(function()
                local w = Work:get()
                if not w then return end
                local wt = nil
                pcall(function() wt = w:GetWorkType() end)
                if type(wt) ~= "number" or wt < core.WORK_MIN or wt > core.WORK_MAX then return end
                pending[wt] = { lastSeen = os.time() }
            end)
            if not ok then logOnce("assignhook", "OnRequiredAssignWork handler error: " .. tostring(err)) end
        end)
end)
log(okA and "HOOK OK OnRequiredAssignWork_ServerInternal"
    or ("HOOK FAILED OnRequiredAssignWork_ServerInternal: " .. tostring(errA)))

-- (B) Toggle observer — combines what used to be two separate mods' hooks on
-- the same function into one: every role sends a PrioMod_Dir attestation for
-- a click it originates (skipped for our own internalCall writes), and only
-- the server-authoritative role acts on the result. In singleplayer/listen-
-- server, both halves run in the same process for the same click — the
-- marker is set and consumed within the same tick, which the existing 1s
-- staleness window comfortably covers.
local okB, errB = pcall(function()
    RegisterHook("/Script/Pal.PalNetworkBaseCampComponent:RequestChangeWorkSuitability_ToServer",
        function(Context, TargetIndividualId, WorkSuitability, bOn)
            pcall(function()
                if isServer and not campComp then campComp = Context:get() end
            end)
            if internalCall then return end

            local compName = nil
            pcall(function()
                local c = Context:get()
                if c and c.IsValid and c:IsValid() then compName = c:GetFullName() end
            end)

            -- Every role attests the click it's originating (skip if this is
            -- itself the authoritative side re-processing after attesting —
            -- guarded by internalCall above already).
            if compName then
                pcall(function()
                    local comp = Context:get()
                    if comp and comp.IsValid and comp:IsValid() then
                        comp:Request_Server_int32({ A = 0, B = 0, C = 0, D = 0 }, FName("PrioMod_Dir"), 1)
                    end
                end)
            end

            if not isServer then return end -- only the authority decides anything further

            local ok, err = pcall(function()
                local id = TargetIndividualId:get()
                local work = WorkSuitability:get()
                local on = bOn:get()
                local key = core.palKey(id.PlayerUId, id.InstanceId)
                local cfg = config.pals[key]

                local dirStep = nil
                if compName then
                    local m = pendingDirByComp[compName]
                    if m and (os.clock() - m.at) < 1.0 then
                        dirStep = m.dir
                        pendingDirByComp[compName] = nil
                    end
                end

                if dirStep == nil then
                    if not cfg then return end
                    local fid, fparam = findPalByKey(key)
                    if fparam then
                        local raw = cfg.raw
                        for t = core.WORK_MIN, core.WORK_MAX do
                            if t ~= work then
                                local has = false
                                pcall(function() has = fparam:HasWorkSuitability(t) end)
                                if has then
                                    local wantOn = (cfg.prio[t] or 0) >= 1
                                    sendToggle(raw, t, wantOn)
                                end
                            end
                        end
                    end
                    config.pals[key] = nil
                    persist()
                    log(string.format("released [%s]: unattested toggle — pal returned to vanilla on/off",
                        cfg.name or key))
                    return
                end

                local fid, fparam = findPalByKey(key)
                if not cfg then
                    if not fparam then return end
                    local prio = {}
                    local nInit = 0
                    for t = core.WORK_MIN, core.WORK_MAX do
                        local okh, has = pcall(function() return fparam:HasWorkSuitability(t) end)
                        if okh and has then
                            prio[t] = core.vanillaDefault(t == work and on or false)
                            nInit = nInit + 1
                        end
                    end
                    local raw = {
                        PlayerUId  = { A = id.PlayerUId.A,  B = id.PlayerUId.B,
                                       C = id.PlayerUId.C,  D = id.PlayerUId.D },
                        InstanceId = { A = id.InstanceId.A, B = id.InstanceId.B,
                                       C = id.InstanceId.C, D = id.InstanceId.D },
                    }
                    local name = nil
                    pcall(function() name = fparam:GetDisplayName() end)
                    cfg = { name = name or key, prio = prio, raw = raw }
                    config.pals[key] = cfg
                    log(string.format("auto-config [%s]: %d work type(s) initialized", cfg.name, nInit))
                end

                local newPrio = core.cycleStep(cfg.prio[work], dirStep)
                cfg.prio[work] = newPrio
                persist()
                log(string.format("cycle [%s] worktype=%d -> %d", cfg.name or key, work, newPrio))

                if fparam then
                    sendToggle(cfg.raw, work, newPrio >= 1)
                end
            end)
            if not ok then logOnce("togglehook", "toggle handler error: " .. tostring(err)) end
        end)
end)
log(okB and "HOOK OK RequestChangeWorkSuitability_ToServer"
    or ("HOOK FAILED RequestChangeWorkSuitability_ToServer: " .. tostring(errB)))

-- (C) Tagged-message transport (PrioMod_* over Request_Server_int32) —
-- receiving/recording state is server-role-only; every role can still SEND
-- through this same RPC (see (B) above and the click-sending section below).
local okC, errC = pcall(function()
    RegisterHook("/Script/Pal.PalNetworkBaseCampComponent:Request_Server_int32",
        function(Context, BaseCampId, FunctionName, Value)
            if not isServer then return end
            local ok, err = pcall(function()
                local name = FunctionName:get():ToString()
                if type(name) ~= "string" or name:sub(1, 8) ~= "PrioMod_" then return end

                local compName = nil
                pcall(function()
                    local c = Context:get()
                    if c and c.IsValid and c:IsValid() then compName = c:GetFullName() end
                end)
                if compName then moddedComps[compName] = os.clock() end

                if name == "PrioMod_Ping" then
                    log(string.format("PrioMod_Ping received%s", compName and (" on " .. compName) or ""))
                    return
                end

                if name == "PrioMod_Dir" then
                    if compName then
                        local v = Value:get()
                        pendingDirByComp[compName] = { dir = (v and v < 0) and -1 or 1, at = os.clock() }
                    end
                    return
                end

                if name == "PrioMod_SetPrio" then
                    local v = Value:get()
                    if type(v) ~= "number" then return end
                    local workType = math.floor(v / 100)
                    local prio = core.clampPrio(v % 100)
                    if workType < core.WORK_MIN or workType > core.WORK_MAX then return end
                    if compName then
                        pendingSetPrioByComp[compName] = { workType = workType, prio = prio, at = os.clock() }
                    end
                    return
                end

                logOnce("prio:" .. name, "unrecognized PrioMod command: " .. name)
            end)
            if not ok then logOnce("transporthook", "Request_Server_int32 handler error: " .. tostring(err)) end
        end)
end)
log(okC and "HOOK OK Request_Server_int32"
    or ("HOOK FAILED Request_Server_int32: " .. tostring(errC)))

-- ===========================================================================
-- CLIENT-ROLE LOGIC — render/injection/click-sending. Runs unconditionally;
-- naturally inert without a local player UI (never present on a dedicated
-- server, since FindAllOf(MENU_CLASS) simply finds nothing there).
-- ===========================================================================

local displayPrio = {} -- palKey -> { [workType] = prio } — populated locally
-- when isServer (same-process config IS the display state); populated by
-- Task 7's server->client push for a pure remote client.
if isServer then
    for k, e in pairs(config.pals) do displayPrio[k] = e.prio end
end

local MENU_CLASS = "WBP_WorkSuitabilityPreferenceMenu_C"
local CELL_CLASS = "WBP_WorkSuitabilityPreference_CheckBox_0_C"
local ROW_CLASS  = "WBP_WorlSuitabilityPreference_PalList_C" -- game's own typo, keep exact

local function classNameOf(obj)
    local name = nil
    pcall(function() name = obj:GetClass():GetFName():ToString() end)
    return name
end

local function alive(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local rowKeyCache = {}
local bindHooked = false
local menuLikelyOpen = false

local ROW_BP_CLASS = "/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/WorkSuitabilityPreference/WBP_WorlSuitabilityPreference_PalList.WBP_WorlSuitabilityPreference_PalList_C"
local ROW_BIND_FN = ROW_BP_CLASS .. ":BindFromSlot"

local function tryHookBind()
    if bindHooked then return end
    pcall(function() LoadAsset(ROW_BP_CLASS) end)
    local ok = pcall(function()
        RegisterHook(ROW_BIND_FN, function(Context, SlotParam)
            pcall(function()
                local row = Context:get()
                if not alive(row) then return end
                local rname = row:GetFullName()
                local slot = SlotParam:get()
                if not alive(slot) then return end
                local handle = slot.Handle
                if not alive(handle) then return end
                local id = handle:GetIndividualID()
                if id == nil then return end
                local okk, key = pcall(function() return core.palKey(id.PlayerUId, id.InstanceId) end)
                if okk and key then
                    local raw = nil
                    pcall(function()
                        raw = {
                            PlayerUId  = { A = id.PlayerUId.A,  B = id.PlayerUId.B,
                                           C = id.PlayerUId.C,  D = id.PlayerUId.D },
                            InstanceId = { A = id.InstanceId.A, B = id.InstanceId.B,
                                           C = id.InstanceId.C, D = id.InstanceId.D },
                        }
                    end)
                    rowKeyCache[rname] = { key = key, raw = raw }
                    menuLikelyOpen = true
                end
            end)
        end)
    end)
    if ok then
        bindHooked = true
        log("BindFromSlot hook registered — row->pal mapping active")
    end
end

local function rowOfCell(cell)
    local node = nil
    pcall(function() node = cell:GetParent() end)
    if not alive(node) then return nil end
    for _ = 1, 5 do
        if classNameOf(node) == ROW_CLASS then return node end
        local outer = nil
        pcall(function() outer = node:GetOuter() end)
        if not alive(outer) then return nil end
        node = outer
    end
    return nil
end

local function resolveKey(rowName)
    local e = rowKeyCache[rowName]
    return e and e.key or nil
end

local function resolveRaw(rowName)
    local e = rowKeyCache[rowName]
    return e and e.raw or nil
end

local injected = {}
local lastText = {}
local ftextMethod = nil
local kismetLib = nil

local function makeFText(str)
    if ftextMethod == "direct" then
        local ft = nil
        if pcall(function() ft = FText(str) end) then return ft end
        return nil
    elseif ftextMethod == "kismet" then
        if not kismetLib then return nil end
        local ft = nil
        if pcall(function() ft = kismetLib:Conv_StringToText(str) end) then return ft end
        return nil
    end
    local ft = nil
    if pcall(function() ft = FText(str) end) and ft ~= nil then
        ftextMethod = "direct"
        return ft
    end
    local lib = nil
    pcall(function() lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary") end)
    if lib then
        if pcall(function() ft = lib:Conv_StringToText(str) end) and ft ~= nil then
            ftextMethod = "kismet"
            kismetLib = lib
            return ft
        end
    end
    logOnce("ftext", "no working FText construction path found — numbers cannot render")
    return nil
end

local function setText(tb, cellName, str)
    local ft = makeFText(str)
    if ft == nil then return end
    if pcall(function() tb:SetText(ft) end) then lastText[cellName] = str end
end

local function injectAtCheckbox(cell, tb)
    local cb = nil
    pcall(function() cb = cell.PalCheckBox end)
    if not alive(cb) then return false end
    local parent = nil
    pcall(function() parent = cb:GetParent() end)
    if not alive(parent) then return false end
    local cbSlot = nil
    pcall(function() cbSlot = cb.Slot end)
    if not alive(cbSlot) then return false end
    local newSlot = nil
    if not pcall(function() newSlot = parent:AddChild(tb) end) or not alive(newSlot) then return false end
    local slotCls = classNameOf(cbSlot) or ""
    if slotCls == "CanvasPanelSlot" then
        pcall(function() newSlot:SetAnchors(cbSlot:GetAnchors()) end)
        pcall(function() newSlot:SetPosition(cbSlot:GetPosition()) end)
        pcall(function() newSlot:SetSize(cbSlot:GetSize()) end)
        pcall(function() newSlot:SetAlignment(cbSlot:GetAlignment()) end)
        pcall(function() newSlot:SetZOrder(cbSlot:GetZOrder() + 1) end)
    else
        pcall(function() newSlot:SetHorizontalAlignment(cbSlot.HorizontalAlignment) end)
        pcall(function() newSlot:SetVerticalAlignment(cbSlot.VerticalAlignment) end)
        pcall(function() newSlot:SetPadding(cbSlot.Padding) end)
    end
    return true
end

local function ensureTextBlock(cell, cellName)
    local cached = injected[cellName]
    if cached then
        if alive(cached) then return cached end
        injected[cellName] = nil
        lastText[cellName] = nil
    end
    local tree = nil
    pcall(function() tree = cell.WidgetTree end)
    if not alive(tree) then return nil end
    local tbClass = nil
    pcall(function() tbClass = StaticFindObject("/Script/UMG.TextBlock") end)
    if not tbClass then return nil end
    local tb = nil
    pcall(function() tb = StaticConstructObject(tbClass, tree) end)
    if not alive(tb) then return nil end
    if not injectAtCheckbox(cell, tb) then return nil end
    pcall(function() tb:SetVisibility(3) end)
    pcall(function() tb:SetJustification(1) end)
    pcall(function()
        tb:SetColorAndOpacity({ SpecifiedColor = { R = 1.0, G = 0.85, B = 0.1, A = 1.0 }, ColorUseRule = 0 })
    end)
    injected[cellName] = tb
    return tb
end

local function handleCell(cell, prioForType)
    if not alive(cell) then return end
    local cellName = nil
    pcall(function() cellName = cell:GetFullName() end)
    if not cellName or cellName:find("Default__", 1, true) then return end
    local battle = false
    pcall(function() battle = cell.IsBattleSettingMode end)
    if battle == true then return end
    local t = nil
    pcall(function() t = cell.BindedSuitability end)
    if type(t) ~= "number" or t <= 0 then return end

    local prio = prioForType and prioForType[t] or nil
    local desired = core.prioDisplayText(prio)
    if prio == nil then
        if injected[cellName] and lastText[cellName] ~= "" then
            setText(injected[cellName], cellName, "")
        end
        return
    end
    local tb = ensureTextBlock(cell, cellName)
    if not tb then return end
    if lastText[cellName] ~= desired then
        setText(tb, cellName, desired)
    end
end

local function handleCellTop(cell)
    if not alive(cell) then return end
    local row = rowOfCell(cell)
    if not row then return end
    local rowName = nil
    pcall(function() rowName = row:GetFullName() end)
    if not rowName then return end
    local key = resolveKey(rowName)
    if not key then return end
    handleCell(cell, displayPrio[key])
end

local menuRef = nil
local function isShowing(m)
    local okv, vis = pcall(function() return m:IsVisible() end)
    if not okv then return true end
    return vis == true
end

local function menuIsShowing()
    if alive(menuRef) and isShowing(menuRef) then return true end
    menuRef = nil
    local menus = nil
    pcall(function() menus = FindAllOf(MENU_CLASS) end)
    if not menus then return false end
    for _, m in ipairs(menus) do
        if alive(m) then
            local mname = nil
            pcall(function() mname = m:GetFullName() end)
            if mname and not mname:find("Default__", 1, true) and isShowing(m) then
                menuRef = m
                return true
            end
        end
    end
    return false
end

local helloSent = false

-- INTERIM component resolution — see Task 6/7. FindFirstOf grabs whichever
-- instance the engine enumerates first, not necessarily this client's own
-- base, and is proven broken for a world with multiple bases.
local function findOwnComp()
    return FindFirstOf("PalNetworkBaseCampComponent")
end

local function tickBody()
    tryHookBind()
    if not menuIsShowing() then
        menuLikelyOpen = false
        return
    end
    if not isServer and not helloSent then
        pcall(function()
            local comp = findOwnComp()
            if alive(comp) then
                comp:Request_Server_int32({ A = 0, B = 0, C = 0, D = 0 }, FName("PrioMod_Ping"), 1)
                helloSent = true
            end
        end)
    end
    local cells = nil
    pcall(function() cells = FindAllOf(CELL_CLASS) end)
    if not cells then return end
    for _, cell in ipairs(cells) do
        pcall(handleCellTop, cell)
    end
end

local function cellUnderCursor()
    local cells = nil
    pcall(function() cells = FindAllOf(CELL_CLASS) end)
    if not cells then return nil end
    for _, cell in ipairs(cells) do
        local hovered = false
        pcall(function() if alive(cell) then hovered = cell:IsHovered() end end)
        if hovered then return cell end
    end
    return nil
end

local function sendDirectRpc(cell, dir)
    local t = nil
    pcall(function() t = cell.BindedSuitability end)
    if type(t) ~= "number" or t <= 0 then return end
    local row = rowOfCell(cell)
    if not row then return end
    local rname = nil
    pcall(function() rname = row:GetFullName() end)
    local raw = rname and resolveRaw(rname) or nil
    if not raw then return end

    pcall(function()
        local comp = findOwnComp()
        if alive(comp) then
            comp:Request_Server_int32({ A = 0, B = 0, C = 0, D = 0 }, FName("PrioMod_Dir"), dir)
        end
    end)
    internalCall = true
    pcall(function()
        local comp = findOwnComp()
        if alive(comp) then
            comp:RequestChangeWorkSuitability_ToServer(
                { PlayerUId = raw.PlayerUId, InstanceId = raw.InstanceId, DebugName = "" }, t, false)
        end
    end)
    internalCall = false
end

pcall(function()
    local rmb = Key.RIGHT_MOUSE_BUTTON
    if rmb then
        RegisterKeyBind(rmb, function()
            if not menuLikelyOpen then return end
            local cell = cellUnderCursor()
            if cell then sendDirectRpc(cell, -1) end
        end)
        log("right-click decrement bound")
    end
end)

pcall(function()
    local mmb = Key.MIDDLE_MOUSE_BUTTON
    if mmb then
        RegisterKeyBind(mmb, function()
            if not menuLikelyOpen then return end
            local cell = cellUnderCursor()
            if not cell then return end
            local t = nil
            pcall(function() t = cell.BindedSuitability end)
            if type(t) ~= "number" or t <= 0 then return end
            local row = rowOfCell(cell)
            if not row then return end
            local rname = nil
            pcall(function() rname = row:GetFullName() end)
            local key = rname and resolveKey(rname) or nil
            if not key then return end
            local current = (displayPrio[key] and displayPrio[key][t]) or 0
            local jumped = current + 5
            if jumped > core.PRIO_MAX then jumped = jumped - (core.PRIO_MAX + 1) end
            pcall(function()
                local comp = findOwnComp()
                if alive(comp) then
                    comp:Request_Server_int32({ A = 0, B = 0, C = 0, D = 0 },
                        FName("PrioMod_SetPrio"), t * 100 + jumped)
                end
            end)
        end)
        log("middle-click +5 jump bound")
    else
        log("Key.MIDDLE_MOUSE_BUTTON not available in this UE4SS build — +5 jump disabled")
    end
end)

pcall(function()
    LoopAsync(500, function()
        local ok = pcall(function()
            if bindHooked and not menuLikelyOpen then return end
            ExecuteInGameThread(function()
                local okt, errt = pcall(tickBody)
                if not okt then logOnce("tick", "tick error: " .. tostring(errt)) end
            end)
        end)
        if not ok then logOnce("loop", "LoopAsync error") end
        return false
    end)
end)

pcall(function()
    ExecuteInGameThread(function() pcall(tryHookBind) end)
end)

log(string.format("v%s ready.", VERSION))
```

- [ ] **Step 2: Commit**

```bash
cd /home/niklas/PalJobsPreferred
git add PalJobsPreferred/Scripts/main.lua
git commit -m "Add single-mod main.lua: role-detected server logic + client render/click-send"
```

---

## Task 4: Stand up the disposable research server

**Files:**
- Create: `/home/niklas/PalJobsPreferred/research-server/docker-compose.yml`
- Create: `/home/niklas/PalJobsPreferred/research-server/stack.env`

**Interfaces:** None — infrastructure only. Produces a running container
`palworld-research-server`.

- [ ] **Step 1: Write the compose file**

```yaml
networks:
  palworld-research:

services:
  palworld-dedicated-server:
    container_name: palworld-research-server
    image: ghcr.io/ripps818/docker-palworld-dedicated-server-wine:latest
    restart: "no"
    logging:
      driver: "local"
      options:
        max-size: "10m"
        max-file: "3"
    ports:
      - target: 8215
        published: 8241
        protocol: udp
        mode: host
      - target: 8216
        published: 8242
        protocol: tcp
        mode: host
      - target: 25576
        published: 25595
        protocol: tcp
        mode: host
      - target: 27016
        published: 27045
        protocol: tcp
    env_file:
      - ./stack.env
    volumes:
      - /mnt/config/palworld-research:/palworld
    networks:
      - palworld-research
```

- [ ] **Step 2: Write a minimal stack.env**

```
PUID=1000
PGID=1000
TZ=Europe/Berlin
ALWAYS_UPDATE_ON_START=true
STEAMCMD_VALIDATE_FILES=true
BACKUP_ENABLED=false
RESTART_ENABLED=false
PLAYER_DETECTION_ENABLED=false
RCON_PLAYER_DETECTION=false
WORKSHOP_MOD_IDS=""
INSTALL_UE4SS_EXPERIMENTAL=true
UE4SS_EXPERIMENTAL_URL="https://github.com/Okaetsu/RE-UE4SS/releases/download/experimental-palworld/UE4SS-Palworld.zip"
SERVER_SETTINGS_MODE=auto
NOSTEAM_ENABLED=true
SERVER_NAME=PalJobsPreferred-research
SERVER_DESCRIPTION=Disposable research server - not for play
ADMIN_PASSWORD=research
SERVER_PASSWORD=research
MAX_PLAYERS=4
PUBLIC_PORT=8241
RCON_ENABLED=false
RESTAPI_ENABLED=false
```

- [ ] **Step 3: Bring it up and verify it boots healthy**

```bash
mkdir -p /mnt/config/palworld-research
cd /home/niklas/PalJobsPreferred/research-server
docker compose -p paljobspreferred-research up -d
```

Poll:

```bash
docker ps --filter name=palworld-research-server --format '{{.Status}}'
```

Expected, once ready: `Up X minutes (healthy)`. If not, check
`docker logs --tail 50 palworld-research-server`.

- [ ] **Step 4: Commit**

```bash
cd /home/niklas/PalJobsPreferred
git add research-server/docker-compose.yml research-server/stack.env
git commit -m "Add disposable research server compose stack"
```

---

## Task 5: Deploy the mod to the research server and verify role detection + hooks

**Files:** None created — deployment and live verification of Tasks 2 and 3's output.

- [ ] **Step 1: Deploy and verify role detection on the (currently player-less) dedicated research server**

```bash
mkdir -p /mnt/config/palworld-research/Mods/NativeMods/PalJobsPreferred
cp -r /home/niklas/PalJobsPreferred/PalJobsPreferred/* \
  /mnt/config/palworld-research/Mods/NativeMods/PalJobsPreferred/
docker restart palworld-research-server
```

Wait ~30 seconds, then:

```bash
docker exec palworld-research-server grep -n "PalJobsPreferred" \
  /palworld/Pal/Binaries/Win64/ue4ss/UE4SS.log
```

**This is the critical first check.** Expected line: `role:
server-authoritative` (this process has no local player — it's a dedicated
server — so `IsServer()` must read true here). If instead you see `role:
client-only`, or an `IsServer() call failed` / `KismetSystemLibrary not
found` line, **stop** — the role-detection mechanism doesn't work as
expected on this UE4SS build, and needs a different signal before anything
else can be trusted. In that case, the fallback to try next: check whether
`UGameplayStatics` exposes `GetPlayerController` and treat "no local
player controller exists" as the dedicated-server signal instead (this
alone can't distinguish listen-server-host from pure-client, but is
sufficient to confirm/deny dedicated-server detection specifically, which is
what this step is testing) — try
`StaticFindObject("/Script/Engine.Default__GameplayStatics")` then
`:GetPlayerController(WorldContextObject, 0)` with a plausible
`WorldContextObject` (e.g. the same default object) and see whether it
reliably returns nil here. Document whatever is found in
`research-server/FINDINGS.md` before proceeding to Step 2.

Also expected in the same log: `HOOK OK OnRequiredAssignWork_ServerInternal`,
`HOOK OK RequestChangeWorkSuitability_ToServer`, `HOOK OK
Request_Server_int32`, `right-click decrement bound`, `middle-click +5 jump
bound` (or its fallback line), ending with `v1.0.0 ready.`.

- [ ] **Step 2: Live client verification (requires the user) — confirms client-role detection too**

Ask the user to install the **same, unmodified** `PalJobsPreferred` mod
folder into their own Palworld client's `Mods/NativeMods/` and connect to
the research server (`<research-server-host-ip>:8241`, password
`research`). Have them check their own client's `UE4SS.log` for `role:
client-only` (confirming `IsServer()` correctly reads false on a pure
connecting client, not just correctly true on the dedicated server checked
in Step 1 — both directions need confirming since a detection mechanism
that's only ever tested one way could still be subtly wrong).

Then have them open the work-suitability screen at their base and
left-click one work type once. Check the research server:

```bash
docker exec palworld-research-server grep -n "PrioMod_Ping\|PrioMod_Dir\|auto-config\|cycle \[" \
  /palworld/Pal/Binaries/Win64/ue4ss/UE4SS.log
```

Expected: `PrioMod_Ping received`, then `auto-config [...]` and `cycle
[...] worktype=N -> 1`. This single-base scenario is expected to work even
with the interim `FindFirstOf` component resolution — if it doesn't, stop
and diagnose before Task 6 (a failure here would be a different, more basic
bug than the multi-base one Task 6 investigates).

- [ ] **Step 3: No commit** — deployment and verification only.

---

## Task 6: Research — multi-base component resolution + server→client channel

**Files:**
- Create: `/home/niklas/PalJobsPreferred/research-server/FINDINGS.md`

**Interfaces:** None — this task's output is written findings, consumed by
Task 7's code changes.

This is exploratory work against the disposable server, never the live one.
Two related questions, investigated together since both require the same
kind of live UE4SS class/property inspection:

1. **How does a client correctly resolve *its own* `PalNetworkBaseCampComponent`**, replacing the interim `FindFirstOf` (proven broken for >1 base)?
2. **Is there an existing client-bound RPC or replicated property** on `PalNetworkBaseCampComponent` or a related class usable as a server→client push channel, mirroring how `Request_Server_int32` already works client→server?

- [ ] **Step 1: Set up a second test base on the research server**

Ask the user (or use a second test account) to create a second player/base
on the research server, so there are genuinely 2+ bases to test resolution
against — matching the real live server's multi-base situation this needs
to work correctly for.

- [ ] **Step 2: Generate a UE4SS SDK header dump**

Per UE4SS's own `UE4SS-settings.ini` documentation, this can be memory-
intensive and carries a stated crash risk — exactly why it happens here and
not on the live server. Trigger it via the in-game UE4SS console (if
`ConsoleEnabled=1` is set temporarily in
`/mnt/config/palworld-research/Pal/Binaries/Win64/ue4ss/UE4SS-settings.ini`)
or via a short-lived Lua console command registered for this purpose. Record
the exact steps taken and outcome in `FINDINGS.md`.

- [ ] **Step 3: Inspect `PalNetworkBaseCampComponent`'s owning chain**

Using the dump (or UE4SS's live property/object browser if the dump isn't
usable), find how a `PalNetworkBaseCampComponent` relates to its owning
player/base — e.g. an `Owner` property, an `OwnerPlayerUId`-style field, or
similar. Cross-reference against the local player controller/pawn to
determine a resolution rule.

- [ ] **Step 4: Inspect for a client-bound RPC or replicated property**

Look for a `Client_*`-prefixed function or a plain replicated property on
`PalNetworkBaseCampComponent` (or a related class in the same header) that
could carry a small tagged payload the way `Request_Server_int32` does in
the other direction.

- [ ] **Step 5: Write `FINDINGS.md`**

Document exactly what was found for both questions — the resolution rule
(with the specific property/method chain to use) and the server→client
channel candidate (or the conclusion that none was found, with what was
tried). This becomes the input to Task 7's patch.

- [ ] **Step 6: Commit**

```bash
cd /home/niklas/PalJobsPreferred
git add research-server/FINDINGS.md
git commit -m "Document research findings: component resolution and server->client channel"
```

---

## Task 7: Apply research findings to main.lua

**Files:**
- Modify: `/home/niklas/PalJobsPreferred/PalJobsPreferred/Scripts/main.lua`

**Interfaces:** Unchanged externally — this task patches the interim
`findOwnComp()` function and, if Task 6 found a usable channel, adds a push
path from the server-authoritative role's `persist()` to connected clients
and a receive path updating `displayPrio` on the client role.

This task's exact code depends entirely on Task 6's findings and can't be
written until that task completes — write it directly against what
`FINDINGS.md` documents, following the same patterns already established in
this file (pcall-wrapped, `alive()`-checked, `logOnce` for degraded paths).
If Task 6 found no usable server→client channel, skip the push/receive
addition — the mod still ships fully correct on the toggle/priority side
(which does not depend on this), with the live overlay staying accurate
only "as of when the work screen was opened" rather than continuously live,
per the design doc's documented fallback.

- [ ] **Step 1: Patch `findOwnComp()` with the correct resolution**

- [ ] **Step 2: Re-deploy to the research server and re-run Task 5 Step 2's live multi-base test**, this time with the user's second test base — confirm both bases' toggles now resolve to the correct component and don't cross-contaminate.

- [ ] **Step 3: If a push channel was found, wire it in and verify a change made by one client's click appears live in a second observer's overlay** (either the second test player, or the same player reopening the screen) without needing to reconnect.

- [ ] **Step 4: Commit**

```bash
cd /home/niklas/PalJobsPreferred
git add PalJobsPreferred/Scripts/main.lua
git commit -m "Apply research findings: correct component resolution$(test -f research-server/FINDINGS.md && grep -q 'channel found' research-server/FINDINGS.md && echo ' + live push channel')"
```

---

## Task 8: Deploy to the live server and tear down research

**Files:** None created.

- [ ] **Step 1: Remove the old mods from the live server**

```bash
rm -rf /mnt/config/palworld-modded/Mods/NativeMods/PalPriority
```

(The old client-side `PalPriorityUI` lives on players' own PCs, not this
server — ask them to remove it themselves when they install the new one.)

- [ ] **Step 2: Deploy the new single mod**

```bash
cp -r /home/niklas/PalJobsPreferred/PalJobsPreferred \
  /mnt/config/palworld-modded/Mods/NativeMods/PalJobsPreferred
docker restart palworld-wine-server
```

- [ ] **Step 3: Verify on the live server**

```bash
docker exec palworld-wine-server grep -n "PalJobsPreferred" \
  /palworld/Pal/Binaries/Win64/ue4ss/UE4SS.log
```

Expected: `role: server-authoritative`, all three `HOOK OK` lines, `v1.0.0
ready.` — same checklist as Task 5 Step 1, now on the real server.

- [ ] **Step 4: Ask both real players to install the same mod folder client-side and test**

With the real 2-player, 3-base world — the actual scenario every earlier
bug in this project came from. Confirm toggles cycle correctly for both
players across all three bases with no cross-contamination.

- [ ] **Step 5: Tear down the disposable research server**

```bash
cd /home/niklas/PalJobsPreferred/research-server
docker compose -p paljobspreferred-research down -v
rm -rf /mnt/config/palworld-research
```

- [ ] **Step 6: Update the design doc's architecture section** to match the
single-mod design (see the note in this plan's File Structure section), and
commit.

```bash
cd /home/niklas/PalJobsPreferred
git add docs/superpowers/specs/2026-07-17-paljobspreferred-design.md
git commit -m "Update design doc to reflect single self-detecting mod architecture"
```
