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
-- CRASH-CRITICAL: UE4SS returns a WRAPPER object (not nil) for a null/stale
-- UObject, and calling a method on it can crash NATIVELY — pcall cannot
-- catch that, since the crash happens in native code before Lua sees
-- anything. Always check IsValid() (itself safe on null/stale wrappers)
-- before any further method call. Defined early (moved up from its original
-- position further down this file) because checkIsServer() below needs it.
-- ---------------------------------------------------------------------------
local function alive(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

-- ---------------------------------------------------------------------------
-- Role detection. LIVE-VERIFIED (Task 5): KismetSystemLibrary::IsServer()
-- requires an explicit world-bound WorldContextObject argument (a CDO alone
-- errors with "expected 2 parameters, received 0"; the class default object
-- itself as context returns a wrong `false` since it has no valid World) —
-- a live GameStateBase actor works correctly. It ALSO reads wrong (false,
-- even on a genuine dedicated server) if called synchronously at mod-load
-- time, before the World's NetMode is fully established; called again just
-- a few seconds later it's correct. So this is a function re-checked fresh
-- at each decision point (hooks fire well after startup in practice), never
-- a one-time snapshot cached at load. Uses alive(), not a plain nil check,
-- on both sysLib and gs — a stale-but-non-nil wrapper here would otherwise
-- risk a native crash on :IsServer(gs) (see CRASH-CRITICAL note above).
-- ---------------------------------------------------------------------------
local function checkIsServer()
    local sysLib = nil
    pcall(function() sysLib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
    if not alive(sysLib) then return false end
    local gs = nil
    pcall(function() gs = FindFirstOf("GameStateBase") end)
    if not alive(gs) then return false end
    local result = false
    pcall(function() result = sysLib:IsServer(gs) end)
    return result
end

-- ---------------------------------------------------------------------------
-- Config state (server-authoritative role only writes; every role can read
-- what's on disk, though only the authoritative role's copy is meaningful).
-- Loading is deferred behind the same startup window checkIsServer() needs
-- (see above) — evaluating it synchronously at load would incorrectly see
-- client-only and skip loading a real server's config.
-- ---------------------------------------------------------------------------
local CONFIG_PATH = core.resolveConfigPath()
local config = { pals = {} }
local startupRoleLogged = false

local function persist()
    if not checkIsServer() then return end
    local ok, err = core.saveConfig(config, CONFIG_PATH)
    if not ok then logOnce("save", "config save failed: " .. tostring(err)) end
end

-- ===========================================================================
-- SERVER-AUTHORITATIVE LOGIC — bodies below only act when checkIsServer() is true.
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
    -- campComp is captured once and cached for the mod's lifetime (see hook
    -- B below) — re-checked with alive() on every use, not just a nil check,
    -- since the underlying component could in principle be destroyed/
    -- recreated between capture and a later call.
    if not alive(campComp) then return end
    internalCall = true
    pcall(function()
        campComp:RequestChangeWorkSuitability_ToServer(
            { PlayerUId = raw.PlayerUId, InstanceId = raw.InstanceId, DebugName = "" },
            workType, wantOn)
    end)
    internalCall = false
end

-- (A) Pending-work intake — server role only; harmless no-op elsewhere since
-- the hook body below checks checkIsServer() before doing anything.
local pending = {}

local okA, errA = pcall(function()
    RegisterHook("/Script/Pal.PalBaseCampWorkerDirector:OnRequiredAssignWork_ServerInternal",
        function(Context, Work, RequirementParameter)
            if not checkIsServer() then return end
            local ok, err = pcall(function()
                local w = Work:get()
                if not alive(w) then return end
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
                if checkIsServer() and not campComp then campComp = Context:get() end
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

            if not checkIsServer() then return end -- only the authority decides anything further

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
                    if alive(fparam) then
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
                    if not alive(fparam) then return end
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
            if not checkIsServer() then return end
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
-- on the server-authoritative role (same-process config IS the display
-- state) by the deferred startup block below, once checkIsServer() is
-- reliable; populated by Task 7's server->client push for a pure remote
-- client instead.

local MENU_CLASS = "WBP_WorkSuitabilityPreferenceMenu_C"
local CELL_CLASS = "WBP_WorkSuitabilityPreference_CheckBox_0_C"
local ROW_CLASS  = "WBP_WorlSuitabilityPreference_PalList_C" -- game's own typo, keep exact

local function classNameOf(obj)
    local name = nil
    pcall(function() name = obj:GetClass():GetFName():ToString() end)
    return name
end

-- alive() is defined earlier in this file (checkIsServer() needs it too) —
-- not redefined here.

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
    if not checkIsServer() and not helloSent then
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

-- ---------------------------------------------------------------------------
-- Deferred startup: role log + config load + initial displayPrio population.
-- Retries every 5s (past the window checkIsServer() is unreliable in — see
-- the comment on checkIsServer above) until it reads server-authoritative,
-- rather than trusting a single reading: a one-shot attempt that happened
-- to land on a wrong `false` would permanently skip loading priorities.lua
-- for the rest of the session, and a later successful persist() (triggered
-- by an ordinary player toggle, whose own checkIsServer() call happens much
-- later and would very plausibly read correctly) would then silently
-- overwrite the file with a config missing every previously-saved pal.
-- Bounded at STARTUP_MAX_ATTEMPTS so a genuine pure client — which reads
-- false forever, correctly — eventually settles into a final "client-only"
-- log instead of retrying indefinitely.
-- ---------------------------------------------------------------------------
local STARTUP_MAX_ATTEMPTS = 12 -- 12 * 5s = 60s, generous margin over the ~5s seen in testing
local startupAttempts = 0

pcall(function()
    LoopAsync(5000, function()
        if startupRoleLogged then return true end
        startupAttempts = startupAttempts + 1
        local server = checkIsServer()
        if not server and startupAttempts < STARTUP_MAX_ATTEMPTS then
            return false -- retry at the next tick
        end
        startupRoleLogged = true
        log("role: " .. (server and "server-authoritative" or "client-only"))
        if server then
            local cfg, lerr = core.loadConfig(CONFIG_PATH)
            if cfg then
                config = cfg
                local n = 0
                for _ in pairs(config.pals) do n = n + 1 end
                log(string.format("config loaded: %d pal(s) configured", n))
            else
                log("config load failed (" .. tostring(lerr) .. ") — starting with empty config")
            end
            for k, e in pairs(config.pals) do displayPrio[k] = e.prio end
        end
        return true -- stop retrying: either confirmed server, or gave up after STARTUP_MAX_ATTEMPTS
    end)
end)

log(string.format("v%s ready.", VERSION))
