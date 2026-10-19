-- client/main.lua — Escalation
-- The server owns scoring, tiers, the car sequence and who fell. The client
-- builds the deck as LOCAL objects, drives the car the server hands it, and
-- reports enemy contact on its own car (the push credit for a fall).

local EV  = "spz-escalation:"
local HUD = exports["spz-minigames"]

local active     = false
local live       = false     -- countdown done
local down       = false     -- pushed off, waiting to respawn
local deckReady  = false
local state      = { remain = Config.MatchSec, tier = 1, tiers = Config.Tiers }
local seq        = {}
local myTeam     = nil
local tiles      = {}
local myVeh      = 0
local myBack, myBackH = nil, nil

local TEAM_RGB = { { 235, 64, 64 }, { 59, 130, 246 } }

RegisterNetEvent(EV .. "notify", function(msg, t)
    lib.notify({ description = msg, type = t or "info" })
end)

local function carName(model)
    if not model then return "?" end
    local lbl = GetLabelText(GetDisplayNameFromVehicleModel(GetHashKey(model)))
    if not lbl or lbl == "NULL" or lbl == "" then return model:upper() end
    return lbl
end

-- After a match everyone spawns at the hub's shared return point (DK garage).
local function returnPoint(ped)
    if GetResourceState("spz-minigames") == "started" then
        local ok, p = pcall(function() return exports["spz-minigames"]:ReturnPoint() end)
        if ok and p then return vector3(p.x, p.y, p.z), p.w end
    end
    return GetEntityCoords(ped), GetEntityHeading(ped)
end

local function loadModel(name)
    local hash = GetHashKey(name)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local dl = GetGameTimer() + 10000
    while not HasModelLoaded(hash) and GetGameTimer() < dl do Wait(20) end
    return HasModelLoaded(hash) and hash or nil
end

-- ── Deck ────────────────────────────────────────────────────────────────────

local function placeObj(hash, x, y, z)
    local obj = CreateObjectNoOffset(hash, x, y, z, false, false, false)
    if obj == 0 then return nil end
    SetEntityCoordsNoOffset(obj, x, y, z, false, false, false)
    SetEntityRotation(obj, 0.0, 0.0, 0.0, 2, true)
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    SetEntityDynamic(obj, false)
    SetEntityLodDist(obj, 1000)
    return obj
end

local function clearDeck()
    for _, obj in ipairs(tiles) do if DoesEntityExist(obj) then DeleteEntity(obj) end end
    tiles = {}
end

local function buildDeck()
    clearDeck()
    local hash = Config.TileModel and loadModel(Config.TileModel)
    if hash then
        local _, mx = GetModelDimensions(hash)
        for iy = 0, Config.Grid - 1 do
            for ix = 0, Config.Grid - 1 do
                local x, y = Grid.tileCenter(ix, iy)
                local obj = placeObj(hash, x, y, Config.Center.z - mx.z)
                if obj then tiles[#tiles + 1] = obj end
            end
        end
        return true
    end
    for _, name in ipairs(Config.TileProps or {}) do
        hash = loadModel(name)
        if hash then
            local mn, mx = GetModelDimensions(hash)
            local cap = Config.MaxPropsPerSide or 6
            local nx = math.min(cap, math.max(1, math.ceil(Config.TileSize / math.max(0.5, mx.x - mn.x))))
            local ny = math.min(cap, math.max(1, math.ceil(Config.TileSize / math.max(0.5, mx.y - mn.y))))
            local sx, sy, half = Config.TileSize / nx, Config.TileSize / ny, Config.TileSize * 0.5
            for iy = 0, Config.Grid - 1 do
                for ix = 0, Config.Grid - 1 do
                    local cx, cy = Grid.tileCenter(ix, iy)
                    for a = 0, nx - 1 do
                        for b = 0, ny - 1 do
                            local z = Config.Center.z - mx.z - (((a + b) % 2 == 0) and 0.0 or 0.03)
                            local obj = placeObj(hash, cx - half + (a + 0.5) * sx, cy - half + (b + 0.5) * sy, z)
                            if obj then tiles[#tiles + 1] = obj end
                        end
                    end
                end
                Wait(0)
            end
            return true
        end
    end
    lib.notify({ title = "ESCALATION", description = "The deck could not be built (no tile model loaded).", type = "error" })
    return false
end

-- ── Car ─────────────────────────────────────────────────────────────────────

local function claimCar(netId)
    if not netId then return 0 end
    local dl = GetGameTimer() + 8000
    while not NetworkDoesEntityExistWithNetworkId(netId) and GetGameTimer() < dl do Wait(50) end
    if not NetworkDoesEntityExistWithNetworkId(netId) then
        lib.notify({ title = "ESCALATION", description = "Your car failed to arrive", type = "error" })
        return 0
    end
    local veh = NetToVeh(netId)
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    TaskWarpPedIntoVehicle(ped, veh, -1)
    dl = GetGameTimer() + 3000
    while GetPedInVehicleSeat(veh, -1) ~= ped and GetGameTimer() < dl do Wait(20) end
    dl = GetGameTimer() + 3000
    while not NetworkHasControlOfEntity(veh) and GetGameTimer() < dl do
        NetworkRequestControlOfEntity(veh); Wait(20)
    end
    SetVehicleOnGroundProperly(veh)
    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleNumberPlateText(veh, myTeam == 1 and "RED" or myTeam == 2 and "BLUE" or "SOLO")
    -- Team colour so you can tell friend from foe at a glance.
    local rgb = myTeam and TEAM_RGB[myTeam]
    if rgb then
        SetVehicleCustomPrimaryColour(veh, rgb[1], rgb[2], rgb[3])
        SetVehicleCustomSecondaryColour(veh, rgb[1], rgb[2], rgb[3])
    end
    if Config.CarInvincible then
        SetEntityInvincible(veh, true)
        SetVehicleCanBeVisiblyDamaged(veh, false)
        SetVehicleTyresCanBurst(veh, false)
        SetVehicleWheelsCanBreak(veh, false)
    end
    -- Held still until GO.
    FreezeEntityPosition(veh, not live)
    return veh
end

local function deleteCar()
    if myVeh ~= 0 and DoesEntityExist(myVeh) then
        SetEntityAsMissionEntity(myVeh, true, true)
        DeleteEntity(myVeh)
    end
    myVeh = 0
end

local function despawnFreeroamCar()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return end
    local dl = GetGameTimer() + 1000
    while not NetworkHasControlOfEntity(veh) and GetGameTimer() < dl do
        NetworkRequestControlOfEntity(veh); Wait(0)
    end
    SetEntityAsMissionEntity(veh, true, true)
    DeleteVehicle(veh)
    if DoesEntityExist(veh) then DeleteEntity(veh) end
end

-- ── Contact reports ─────────────────────────────────────────────────────────
-- Whoever's car is touching mine is reported (throttled per player). The
-- server only keeps it if they are an enemy, and only credits it if I fall.

local lastReport = {}
CreateThread(function()
    while true do
        if active and live and not down and myVeh ~= 0 and DoesEntityExist(myVeh) then
            local me = GetEntityCoords(myVeh)
            local now = GetGameTimer()
            for _, v in ipairs(GetGamePool("CVehicle")) do
                if v ~= myVeh and #(GetEntityCoords(v) - me) < 12.0 and IsEntityTouchingEntity(myVeh, v) then
                    local driver = GetPedInVehicleSeat(v, -1)
                    if driver ~= 0 and IsPedAPlayer(driver) then
                        local sid = GetPlayerServerId(NetworkGetPlayerIndexFromPed(driver))
                        if sid and sid > 0 and now - (lastReport[sid] or 0) > 400 then
                            lastReport[sid] = now
                            TriggerServerEvent(EV .. "touched", sid)
                        end
                    end
                end
            end
            Wait(50)
        else
            Wait(250)
        end
    end
end)

-- ── Cleanup ─────────────────────────────────────────────────────────────────

local function cleanup()
    active, live, down, deckReady = false, false, false, false
    HUD:Hud(nil)
    TriggerServerEvent("spz:setPlayerFlag", "inMinigame", false)
    TriggerEvent("spz:minigameChanged")
    clearDeck()
    deleteCar()
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetEntityInvincible(ped, false)
    if myBack then
        SetEntityCoords(ped, myBack.x, myBack.y, myBack.z, false, false, false, false)
        if myBackH then SetEntityHeading(ped, myBackH) end
        myBack = nil
    end
end

local function playClip(name)
    if GetResourceState("spz-raceUI") == "started" then
        local ok = pcall(function() exports["spz-raceUI"]:PlaySound(name, 1.0) end)
        if ok then return end
    end
    PlaySoundFrontend(-1, name == "go" and "GO" or "3_2_1", "HUD_MINI_GAME_SOUNDSET", true)
end

-- ── Round events ────────────────────────────────────────────────────────────

RegisterNetEvent(EV .. "start", function(d)
    -- Set active BEFORE yielding: the server sends `place` right behind
    -- `start`, and a `place` that arrived during the fade used to be dropped
    -- (no car, screen left black).
    active, live, down, deckReady = true, false, false, false
    seq, myTeam = d.seq or {}, d.team
    DoScreenFadeOut(300)
    Wait(300)
    TriggerServerEvent("spz:setPlayerFlag", "inMinigame", "Escalation")
    TriggerEvent("spz:minigameChanged")

    local ped = PlayerPedId()
    myBack, myBackH = returnPoint(ped)
    despawnFreeroamCar()
    SetEntityInvincible(PlayerPedId(), true)
    buildDeck()
    deckReady = true

    local names = {}
    for i, m in ipairs(seq) do names[i] = (i == #seq and "★ " or "") .. carName(m) end
    lib.notify({
        title = d.mode == "team" and ("ESCALATION — %s TEAM"):format(d.teamName or "?") or "ESCALATION — SOLO",
        description = "Push enemies off the deck to climb the cars:\n" .. table.concat(names, " → "),
        type = "inform", duration = 12000,
    })
end)

-- (Re)placed on the deck: stand at the spawn, then ask the server for the car.
RegisterNetEvent(EV .. "place", function(d)
    -- `start` and `place` arrive together: wait for the match to be set up and
    -- the deck to exist before dropping the player (and their car) onto it.
    local dl = GetGameTimer() + 15000
    while not (active and deckReady) and GetGameTimer() < dl do Wait(50) end
    if not active then return end
    down = false
    deleteCar()
    local ped = PlayerPedId()
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    ClearPedTasksImmediately(ped)
    SetEntityCoords(ped, d.spawn.x, d.spawn.y, d.spawn.z + 2.0, false, false, false, false)
    SetEntityHeading(ped, d.heading or 0.0)
    FreezeEntityPosition(ped, true)
    if d.model then loadModel(d.model) end
    Wait(200)
    TriggerServerEvent(EV .. "ready")
    -- not just "fully black": a fade still in progress must come back too
    if not IsScreenFadedIn() then DoScreenFadeIn(500) end
end)

RegisterNetEvent(EV .. "car", function(d)
    if not active then return end
    local keepVel = d.swap and myVeh ~= 0 and DoesEntityExist(myVeh) and GetEntityVelocity(myVeh) or nil
    myVeh = claimCar(d.netId)
    if myVeh == 0 then FreezeEntityPosition(PlayerPedId(), false) return end
    if keepVel and live then SetEntityVelocity(myVeh, keepVel.x, keepVel.y, keepVel.z) end
end)

RegisterNetEvent(EV .. "tier", function(d)
    if not active then return end
    HUD:Flash(d.finale and "FINALE" or ("CAR %d"):format(d.tier), d.finale and "warn" or "ok", 1200)
    lib.notify({
        title = d.finale and "FINALE CAR" or ("Car %d / %d"):format(d.tier, #seq),
        description = d.finale and ("%s — one push in this wins it!"):format(carName(d.model)) or carName(d.model),
        type = d.finale and "warning" or "success", duration = 4000,
    })
    PlaySoundFrontend(-1, "RANK_UP", "HUD_AWARDS", true)
end)

RegisterNetEvent(EV .. "down", function(d)
    if not active then return end
    down = true
    lib.notify({ title = "PUSHED OFF", description = ("Back on the deck in %d s"):format(math.floor(d.respawn or 3)),
                 type = "error", duration = 2500 })
end)

RegisterNetEvent(EV .. "countdown", function(n)
    if not active then return end
    HUD:Flash(tostring(n), nil, 900)
    playClip("countdown")
end)

RegisterNetEvent(EV .. "go", function()
    if not active then return end
    live = true
    if myVeh ~= 0 and DoesEntityExist(myVeh) then FreezeEntityPosition(myVeh, false) end
    HUD:Flash("PUSH!", "ok", 900)
    playClip("go")
end)

RegisterNetEvent(EV .. "feed", function(d)
    lib.notify({ description = ("%s — %s"):format(d.name or "A player", d.why or ""), type = "inform", duration = 2500 })
end)

RegisterNetEvent(EV .. "state", function(s) state = s end)

RegisterNetEvent(EV .. "over", function(r)
    local msg = ("%d push%s"):format(r.pushes or 0, (r.pushes or 0) == 1 and "" or "es")
    if r.winner then msg = ("Winner: %s · %s"):format(r.winner, msg) else msg = "Draw · " .. msg end
    if (r.payout or 0) > 0 then msg = msg .. (" · +%d credits"):format(r.payout) end
    DoScreenFadeOut(400)
    Wait(400)
    cleanup()
    HUD:Shard(r.won and "Victory" or "Match over", msg, r.won and "ok" or "accent", 7000)
    DoScreenFadeIn(600)
end)

-- ── HUD ─────────────────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        if active then
            local t = state.remain or 0
            local finale = (state.tier or 1) >= (state.tiers or Config.Tiers)
            local hud = { chips = {
                ("%d:%02d"):format(math.floor(t / 60), t % 60),
                state.mode == "solo" and "SOLO" or (myTeam == 1 and { text = "RED TEAM", hot = true } or { text = "BLUE TEAM", hot = true }),
                { text = ("Car %d / %d"):format(state.tier or 1, state.tiers or Config.Tiers), hot = finale },
            } }
            if not live then
                hud.status = { label = "Get ready", value = "Escalation", color = "dim" }
            elseif down then
                hud.status = { label = "Pushed off", value = "Respawning", color = "bad" }
            elseif finale then
                hud.status = { label = "Finale", value = carName(state.model), color = "warn", sub = "One push wins it" }
            else
                hud.status = { label = "Driving", value = carName(state.model),
                               sub = ("Next: %s"):format(carName(state.nextModel)) }
                hud.bar = { label = "Next car", pct = (state.progress or 0) / math.max(1, state.need or 1) }
            end
            hud.board = state.board
            -- key bar (live bindings, resolved by spz-minigames)
            hud.keys = hud.keys or {}
            hud.keys[#hud.keys + 1] = { control = 200, default = "ESC", pad = "START_INDEX", label = "Menu · leave" }
            HUD:Hud(hud)
            Wait(100)
        else
            Wait(500)
        end
    end
end)

-- ── Queue menu (the hub is the main way in) ─────────────────────────────────

local function openLobbyMenu()
    local st = lib.callback.await(EV .. "lobbyState", false)
    if not st then return end
    if st.roundLive then
        lib.notify({ description = "Your room is mid-match.", type = "warning" })
        return
    end
    local options = {}
    if st.inLobby then
        options[#options + 1] = {
            title = "Leave Room", icon = "right-from-bracket", iconColor = "#ff4d5e",
            onSelect = function() lib.callback.await(EV .. "leaveRoom", false); openLobbyMenu() end,
        }
        if st.isHost then
            options[#options + 1] = {
                title = "Start match", icon = "play", disabled = st.count < st.min,
                description = st.count < st.min and ("Need %d players"):format(st.min) or nil,
                onSelect = function() lib.callback.await(EV .. "startRoom", false) end,
            }
        end
        options[#options + 1] = { title = ("── %s · %s · %d/%d ──"):format(st.room and st.room.name or "Room",
            (st.room and st.room.mode == "solo") and "Solo" or "Team", st.count, st.max), disabled = true }
        for _, r in ipairs(st.roster or {}) do
            options[#options + 1] = { title = (r.host and "👑 " or "") .. (r.isMe and "★ " or "") .. r.name, disabled = true }
        end
    else
        options[#options + 1] = { title = "Quick Join", icon = "right-to-bracket", iconColor = "#22c55e",
            onSelect = function() lib.callback.await(EV .. "joinToggle", false); openLobbyMenu() end }
        options[#options + 1] = { title = "Create Team room", icon = "users",
            onSelect = function() lib.callback.await(EV .. "createRoom", false, { mode = "team" }); openLobbyMenu() end }
        options[#options + 1] = { title = "Create Solo room", icon = "user",
            onSelect = function() lib.callback.await(EV .. "createRoom", false, { mode = "solo" }); openLobbyMenu() end }
    end
    lib.registerContext({ id = "spz_escalation_lobby", title = "🔺 Escalation", options = options })
    lib.showContext("spz_escalation_lobby")
end

RegisterCommand(Config.MenuCommand, function() openLobbyMenu() end, false)
RegisterKeyMapping(Config.MenuCommand, "Escalation queue menu", "keyboard", "")

RegisterNetEvent(EV .. "invited", function(d)
    -- Racing / queued / in another minigame: a dialog would grab mouse focus
    -- and lock the car mid-race. Just tell them; the invite is kept, so the
    -- room shows as invited in the hub once they are free.
    do
        local st = LocalPlayer.state
        if st.inRace or st.inQueue or st.inMinigame or st.inTimeTrial then
            lib.notify({ title = "Escalation invite",
                description = ("%s invited you to %s — open the minigames hub when you're free."):format(d.fromName or "Someone", d.roomName or "their room"),
                type = "inform", duration = 7000 })
            return
        end
    end
    local resp = lib.alertDialog({
        header = "Escalation Invite",
        content = ("**%s** invited you to **%s** (Escalation)."):format(d.fromName or "Someone", d.roomName or "their room"),
        centered = true, cancel = true,
        labels = { cancel = "Dismiss", confirm = "Join" },
    })
    if resp == "confirm" then TriggerServerEvent(EV .. "acceptInvite", d.room) end
end)

AddEventHandler("spz:leaveMinigame", function()
    if active then TriggerServerEvent(EV .. "leave") end
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() and active then cleanup() end
end)
