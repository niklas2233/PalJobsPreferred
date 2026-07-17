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
