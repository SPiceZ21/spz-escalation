-- server/main.lua — Escalation
-- Like Valorant's Escalation, on wheels. Everyone drives on a Color Rush deck in
-- the sky; pushing an enemy off scores for your side, and enough pushes swap
-- your whole side into the next car of one shared random sequence. A push in
-- the finale car wins; otherwise most pushes when the clock runs out.
-- Team mode (two auto-balanced teams) or solo (everyone for themselves).
--
-- Room / lobby / invite code is shared with spz-colorrush / spz-cyclone.

local Log = SPZ and SPZ.Logger and SPZ.Logger("spz-escalation") or nil
local function log(m) if Log then Log.info(m) else print("[escalation] " .. m) end end

local EV = "spz-escalation:"

local Rooms = {}         -- [id] = { id, name, host, private, max, members = { [src] = { pid, name } }, armed, armedAt, round }
local RoomOf = {}        -- [src] = room
local Invites = {}       -- [src] = { [roomId] = true, last = roomId }
local nextRoomId = 1

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function notify(src, msg, t)
    TriggerClientEvent(EV .. "notify", src, msg, t or "info")
end

local function pidOf(src)
    local ok, p = pcall(function() return exports["spz-identity"]:GetProfile(src) end)
    return ok and p and p.id or nil, ok and p or nil
end

local function nameOf(src)
    local _, prof = pidOf(src)
    return (prof and prof.username) or GetPlayerName(src) or ("Racer" .. src)
end

local function srcFromPid(pid)
    for _, s in ipairs(GetPlayers()) do
        if pidOf(tonumber(s)) == pid then return tonumber(s) end
    end
    return nil
end

local function payPid(pid, amt, reason)
    if not pid or amt <= 0 then return end
    local s = srcFromPid(pid)
    if s and GetResourceState("spz-progression") == "started" then
        exports["spz-progression"]:GrantBonus(s, { credits = amt, reason = reason })
    else
        MySQL.update.await("UPDATE players SET credits = credits + ? WHERE id = ?", { amt, pid })
    end
end

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

local function shuffle(t)
    for i = #t, 2, -1 do local j = math.random(i); t[i], t[j] = t[j], t[i] end
end

local function roundOf(src)
    local room = RoomOf[src]
    local r = room and room.round
    return (r and r.players[src]) and r or nil
end

local function toAll(r, event, payload)
    if not r then return end
    for src in pairs(r.players) do TriggerClientEvent(event, src, payload) end
end

local function aliveList(r)
    local out = {}
    if not r then return out end
    for src, p in pairs(r.players) do
        if p.alive then out[#out + 1] = src end
    end
    return out
end

-- spz-core ghosts every player unless BOTH carry `spz:contact`; round players
-- get it so their cars actually shove each other.
local function setContact(src, on)
    if GetPlayerName(src) then Player(src).state:set("spz:contact", on or nil, true) end
end

-- Cars are created HERE: spz-core buckets run strict entity lockdown and delete
-- networked entities a client creates.
local function spawnCarFor(_, bucketId, x, y, z, heading, model)
    model = model or "blista"
    local veh = CreateVehicleServerSetter(joaat(model), "automobile", x, y, z, heading or 0.0)
    local dl = GetGameTimer() + 3000
    while veh ~= 0 and not DoesEntityExist(veh) and GetGameTimer() < dl do Wait(0) end
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    if bucketId ~= 0 then SetEntityRoutingBucket(veh, bucketId) end
    SetEntityOrphanMode(veh, 2)
    return veh
end

local function deleteCar(p)
    if p and p.veh and DoesEntityExist(p.veh) then DeleteEntity(p.veh) end
    if p then p.veh = nil end
end


-- ── Escalation ──────────────────────────────────────────────────────────────
-- A side = a team (team mode) or one player (solo). Every side climbs the SAME
-- random car sequence: enough pushes -> the whole side swaps to the next car.
-- A push scored while driving the finale car wins outright; otherwise the
-- side with the most pushes when the clock runs out wins.

local TEAM_NAMES  = { "RED", "BLUE" }
local TEAM_COLORS = { { 235, 64, 64 }, { 59, 130, 246 } }

local function eachRound(fn)
    for _, room in pairs(Rooms) do
        if room.round and room.round.active then fn(room.round) end
    end
end

-- Random sequence: Config.Tiers - 1 distinct cars from the pool, then a finale.
local function rollSequence()
    local pool = {}
    for i, m in ipairs(Config.CarPool) do pool[i] = m end
    shuffle(pool)
    local seq = {}
    for i = 1, math.min(Config.Tiers - 1, #pool) do seq[i] = pool[i] end
    local fin = Config.FinalePool
    seq[#seq + 1] = fin[math.random(#fin)]
    return seq
end

local function sideOf(r, src)
    local p = r.players[src]
    return p and r.sides[p.side] or nil
end

local function enemies(r, a, b)
    local pa, pb = r.players[a], r.players[b]
    return pa and pb and pa.side ~= pb.side
end

local function sideLabel(side)
    return side.team and (TEAM_NAMES[side.team] .. " team") or side.name
end

local function deckSpawn(r, side)
    -- Teams start on opposite halves; solo players anywhere on the outer rings.
    local spots = {}
    for iy = 0, Config.Grid - 1 do
        for ix = 0, Config.Grid - 1 do
            local edge = math.min(ix, iy, Config.Grid - 1 - ix, Config.Grid - 1 - iy)
            local ok = edge <= 1
            if side and side.team == 1 then ok = ok and ix < Config.Grid / 2 end
            if side and side.team == 2 then ok = ok and ix >= Config.Grid / 2 end
            if ok then spots[#spots + 1] = { ix, iy } end
        end
    end
    local s = spots[math.random(#spots)]
    local tx, ty = Grid.tileCenter(s[1], s[2])
    local heading = (math.deg(math.atan(Config.Center.y - ty, Config.Center.x - tx)) - 90.0) % 360.0
    return vector3(tx, ty, Config.Center.z + 1.0), heading
end

-- Put a player (back) on the deck in their side's current car.
local function placePlayer(r, src)
    local p = r.players[src]
    if not p or p.left then return end
    deleteCar(p)
    p.onDeck = false
    p.spawn, p.heading = deckSpawn(r, r.sides[p.side])
    p.model = r.seq[r.sides[p.side].tier]
    TriggerClientEvent(EV .. "place", src, { spawn = p.spawn, heading = p.heading, model = p.model })
end

-- Swap a living player's car where it stands (tier up mid-fight).
local function swapCar(r, src)
    local p = r.players[src]
    if not p or p.left or not p.onDeck or not p.veh or not DoesEntityExist(p.veh) then return end
    local c = GetEntityCoords(p.veh)
    local h = GetEntityHeading(p.veh)
    if c.z < Config.Center.z - 2.0 then return end           -- already falling: respawn handles it
    deleteCar(p)
    p.model = r.seq[r.sides[p.side].tier]
    local veh = spawnCarFor(src, r.bucketId or 0, c.x, c.y, math.max(c.z, Config.Center.z + 0.5), h, p.model)
    p.veh = veh
    TriggerClientEvent(EV .. "car", src, { netId = veh and NetworkGetNetworkIdFromEntity(veh) or nil, model = p.model, swap = true })
end

local function endRound(r, why, winnerSide)
    if not r or not r.active then return end
    r.active = false
    r.phase = "over"
    if r.room.round == r then r.room.round = nil end

    -- Winner by time: most pushes; a tie means nobody takes the win reward.
    if not winnerSide then
        local best, tie = nil, false
        for _, s in pairs(r.sides) do
            if not best or s.pushes > best.pushes then best, tie = s, false
            elseif s.pushes == best.pushes then tie = true end
        end
        if best and not tie and best.pushes > 0 then winnerSide = best end
    end

    for src, p in pairs(r.players) do
        deleteCar(p)
        setContact(src, false)
        local won = winnerSide ~= nil and r.sides[p.side] == winnerSide and not p.left
        local total = (p.pushes or 0) * (Config.PushReward or 0)
        if won then total = total + (Config.WinReward or 0) end
        if total > 0 then payPid(p.pid, total, "Escalation") end
        if not p.left then
            TriggerClientEvent(EV .. "over", src, {
                won = won, payout = total, pushes = p.pushes or 0, reason = why,
                winner = winnerSide and sideLabel(winnerSide) or nil,
            })
        end
    end

    SetTimeout(1500, function()
        if r.bucketId and r.bucketId ~= 0 and GetResourceState("spz-core") == "started" then
            exports["spz-core"]:DeleteBucket(r.bucketId)
        end
    end)
    SetTimeout(4000, function()
        if Rooms[r.room.id] ~= r.room then return end
        -- Match over: the room closes and everyone is out of the lobby.
        Rooms[r.room.id] = nil
        for s in pairs(r.room.members) do
            RoomOf[s] = nil
            if GetPlayerName(s) then Player(s).state:set("mgRoom", nil, true) end
            notify(s, "Match over — you left the room. Open the hub to play again.")
        end
    end)

    pcall(function()
        exports["spz-log"]:Log("minigame", "Escalation",
            ("%s — %s (%s)"):format(winnerSide and sideLabel(winnerSide) or "draw", why, r.room.name), "success")
    end)
    log(("room %d match over: %s"):format(r.room.id, why))
end

-- A push landed: credit the pusher's side, maybe tier up, maybe win.
local function scorePush(r, pusher, victim)
    local pp, vp = r.players[pusher], r.players[victim]
    local side = r.sides[pp.side]
    local onFinale = side.tier >= #r.seq
    pp.pushes = (pp.pushes or 0) + 1
    side.pushes = side.pushes + 1
    toAll(r, EV .. "feed", { name = pp.name, why = ("pushed %s off"):format(vp.name), color = side.team })

    if onFinale then
        endRound(r, ("%s scored the finale push"):format(pp.name), side)
        return
    end

    side.progress = side.progress + 1
    local need = r.mode == "solo" and Config.SoloPushesPerTier or Config.TeamPushesPerTier
    if side.progress >= need then
        side.progress = 0
        side.tier = side.tier + 1
        local finale = side.tier >= #r.seq
        for s, p in pairs(r.players) do
            if p.side == pp.side then
                swapCar(r, s)
                TriggerClientEvent(EV .. "tier", s, { tier = side.tier, model = r.seq[side.tier], finale = finale })
            end
        end
        if finale then
            toAll(r, EV .. "feed", { name = sideLabel(side), why = "reached the FINALE car!", color = side.team })
        end
    end
end

-- ── Contact reports + fall watcher ──────────────────────────────────────────
-- The victim's client reports "car X touched me". The server keeps the latest
-- ENEMY contact; if the victim then falls within PushCreditSec, that enemy
-- gets the push. Falling with no recent enemy contact scores nothing.

RegisterNetEvent(EV .. "touched", function(by)
    local src = source
    by = tonumber(by)
    local r = roundOf(src)
    if not r or r.phase ~= "live" or not by or not enemies(r, src, by) then return end
    local p = r.players[src]
    if p.onDeck then p.lastHit = { by = by, at = GetGameTimer() } end
end)

local FALL_DROP = 6.0
CreateThread(function()
    while true do
        Wait(200)
        eachRound(function(r)
            if r.phase ~= "live" then return end
            local now = GetGameTimer()

            if now >= r.endsAt then
                endRound(r, "time up")
                return
            end

            for src, p in pairs(r.players) do
                if p.onDeck and not p.left then
                    local ped = GetPlayerPed(src)
                    if ped ~= 0 then
                        local veh = GetVehiclePedIsIn(ped) or 0
                        local ent = (veh ~= 0 and DoesEntityExist(veh)) and veh or ped
                        if GetEntityCoords(ent).z < (Config.Center.z - FALL_DROP) then
                            p.onDeck = false
                            p.falls = (p.falls or 0) + 1
                            local hit = p.lastHit
                            p.lastHit = nil
                            TriggerClientEvent(EV .. "down", src, { respawn = Config.RespawnSec })
                            if hit and now - hit.at <= Config.PushCreditSec * 1000 and r.players[hit.by] then
                                scorePush(r, hit.by, src)
                                if not r.active then return end
                            else
                                toAll(r, EV .. "feed", { name = p.name, why = "fell off" })
                            end
                            SetTimeout(math.floor(Config.RespawnSec * 1000), function()
                                if r.active and r.players[src] and not r.players[src].left then placePlayer(r, src) end
                            end)
                        end
                    end
                end
            end

            -- Not enough opposition left (everyone on one side quit).
            local live = {}
            for _, p in pairs(r.players) do if not p.left then live[p.side] = true end end
            if count(live) < 2 then endRound(r, "the other side left") end
        end)
    end
end)

-- ── HUD state broadcast ─────────────────────────────────────────────────────

CreateThread(function()
    while true do
        Wait(250)
        eachRound(function(r)
            local now = GetGameTimer()
            local remain = r.endsAt and math.max(0, math.floor((r.endsAt - now) / 1000)) or Config.MatchSec
            local need = r.mode == "solo" and Config.SoloPushesPerTier or Config.TeamPushesPerTier

            local rows = {}
            if r.mode == "team" then
                for i, s in ipairs(r.sides) do
                    rows[#rows + 1] = { name = TEAM_NAMES[i] .. " TEAM", icon = "flag",
                        color = TEAM_COLORS[i], value = ("%d push%s"):format(s.pushes, s.pushes == 1 and "" or "es"),
                        sub = ("Car %d/%d"):format(s.tier, #r.seq) }
                end
                local first = true
                for src, p in pairs(r.players) do
                    if not p.left then
                        rows[#rows + 1] = { src = src, name = p.name, icon = "car-side", sep = first,
                            color = TEAM_COLORS[r.sides[p.side].team], value = tostring(p.pushes or 0) }
                        first = false
                    end
                end
            else
                for src, p in pairs(r.players) do
                    if not p.left then
                        local s = r.sides[p.side]
                        rows[#rows + 1] = { src = src, name = p.name, value = ("%d"):format(s.pushes),
                            sub = ("Car %d/%d"):format(s.tier, #r.seq), _p = s.pushes, _t = s.tier }
                    end
                end
                table.sort(rows, function(a, b)
                    if a._t ~= b._t then return a._t > b._t end
                    return a._p > b._p
                end)
                for _, row in ipairs(rows) do row._p, row._t = nil, nil end
            end

            for src, p in pairs(r.players) do
                local s = r.sides[p.side]
                TriggerClientEvent(EV .. "state", src, {
                    phase = r.phase, mode = r.mode, remain = remain,
                    tier = s.tier, tiers = #r.seq, model = r.seq[s.tier], nextModel = r.seq[s.tier + 1],
                    progress = s.progress, need = need, team = s.team,
                    board = { title = r.mode == "team" and "Teams" or "Standings", rows = rows, numbered = r.mode ~= "team" },
                })
            end
        end)
    end
end)

-- ── Rooms ───────────────────────────────────────────────────────────────────

local function roomMax(room) return room.max or Config.MaxPlayers end
local function disarm(room) room.armed, room.armedAt = false, nil end

local function startRound(room)
    disarm(room)
    if room.round then return end
    if count(room.members) < Config.MinPlayers then
        for s in pairs(room.members) do notify(s, "Not enough players to start.", "warning") end
        return
    end

    local roster = {}
    for src, e in pairs(room.members) do roster[#roster + 1] = { src = src, pid = e.pid, name = e.name } end
    shuffle(roster)

    local bucketId = 0
    if GetResourceState("spz-core") == "started" then
        bucketId = exports["spz-core"]:CreateBucket(("escalation:%d"):format(room.id))
        SetRoutingBucketPopulationEnabled(bucketId, false)
    end

    local mode = room.mode == "solo" and "solo" or "team"
    local r = { room = room, mode = mode, active = true, bucketId = bucketId, players = {}, phase = "build",
                seq = rollSequence(), sides = {} }
    room.round = r

    if mode == "team" then
        r.sides[1] = { team = 1, tier = 1, progress = 0, pushes = 0 }
        r.sides[2] = { team = 2, tier = 1, progress = 0, pushes = 0 }
    end
    for i, m in ipairs(roster) do
        local side
        if mode == "team" then
            side = ((i - 1) % 2) + 1          -- shuffled roster, alternating = balanced teams
        else
            side = i
            r.sides[i] = { name = m.name, tier = 1, progress = 0, pushes = 0 }
        end
        r.players[m.src] = { pid = m.pid, name = m.name, side = side, pushes = 0 }
        pcall(function()
            if GetResourceState("spz-vehicles") == "started" then exports["spz-vehicles"]:DespawnVehicle(m.src) end
        end)
        if bucketId ~= 0 then exports["spz-core"]:AssignPlayerToBucket(m.src, bucketId) end
        setContact(m.src, true)
    end

    for src, p in pairs(r.players) do
        local s = r.sides[p.side]
        TriggerClientEvent(EV .. "start", src, { seq = r.seq, mode = mode, team = s.team,
            teamName = s.team and TEAM_NAMES[s.team] or nil })
        placePlayer(r, src)
    end

    log(("room %d start: %s, %d players, sequence %s"):format(room.id, mode, #roster, table.concat(r.seq, ", ")))

    CreateThread(function()
        Wait(3500)
        for c = 3, 1, -1 do
            if not r.active then return end
            toAll(r, EV .. "countdown", c)
            Wait(1000)
        end
        if not r.active then return end
        r.phase = "live"
        r.endsAt = GetGameTimer() + Config.MatchSec * 1000
        toAll(r, EV .. "go", {})
    end)
end


local function arm(room)
    if room.armed or room.round then return end
    room.armed, room.armedAt = true, GetGameTimer()
    local token = room.armedAt
    SetTimeout((Config.LobbyWaitSec or 45) * 1000, function()
        if Rooms[room.id] == room and room.armed and room.armedAt == token and not room.round then
            CreateThread(function() startRound(room) end)
        end
    end)
end

-- Busy elsewhere → hidden from invite lists. Queued racers still show: joining
-- a room takes them out of the race queue (see leaveRaceQueue).
local function invitable(sid)
    local st = Player(sid).state
    if st.mgRoom or st.inMinigame or st.inRace or st.inTimeTrial or st.inPursuit then return false end
    return true
end

-- Joining a minigame room drops your E-join race queue spot instead of refusing.
local function leaveRaceQueue(src)
    local st = Player(src).state
    if not (st.inQueue or st.pendingRace) or st.inRace then return end
    if GetResourceState("spz-races") ~= "started" then return end
    pcall(function() exports["spz-races"]:LeaveQueue(src) end)
end

local function busy(src)
    if RoomOf[src] then return "already in a room" end
    local st = Player(src).state
    -- One minigame room at a time, across every game.
    if st.mgRoom and st.mgRoom ~= GetCurrentResourceName() then return "already in another minigame room — leave it first" end
    if st.inRace then return "in a race" end
    if st.inTimeTrial then return "in a time trial" end
    return nil
end

local function addMember(room, src)
    local pid, prof = pidOf(src)
    if not pid then return false, "Profile not ready." end
    room.members[src] = { pid = pid, name = (prof and prof.username) or GetPlayerName(src) }
    RoomOf[src] = room
    if Invites[src] then Invites[src][room.id] = nil end
    local n = count(room.members)
    for s in pairs(room.members) do
        if s ~= src then notify(s, ("%s joined %s (%d/%d)"):format(room.members[src].name, room.name, n, roomMax(room)), "success") end
    end
    Player(src).state:set("mgRoom", GetCurrentResourceName(), true)
    leaveRaceQueue(src)
    -- No auto-start: only the room host starts the match.
    return true
end

local function removeMember(src, why)
    local room = RoomOf[src]
    if not room then return end
    local e = room.members[src]
    room.members[src] = nil
    RoomOf[src] = nil
    if GetPlayerName(src) then Player(src).state:set("mgRoom", nil, true) end
    if not next(room.members) then Rooms[room.id] = nil; return end
    if room.host == src then
        room.host = next(room.members)
        notify(room.host, "You are now the room host.", "info")
    end
    if count(room.members) < Config.MinPlayers then disarm(room) end
    for s in pairs(room.members) do
        notify(s, ("%s left the room%s."):format(e and e.name or "Someone", why and (" (" .. why .. ")") or ""), "warning")
    end
end

local function createRoom(src, opts)
    local b = busy(src)
    if b then return false, "You are " .. b .. "." end
    local maxRooms = Config.MaxRooms or 8
    if count(Rooms) >= maxRooms then return false, ("All %d rooms are in use."):format(maxRooms) end
    opts = type(opts) == "table" and opts or {}

    local name = tostring(opts.name or ""):gsub("[^%w%s%-_'!%.]", ""):sub(1, 24)
    if name:match("^%s*$") then name = nameOf(src) .. "'s room" end
    local max = math.floor(tonumber(opts.max) or Config.MaxPlayers)
    max = math.max(Config.MinPlayers, math.min(Config.MaxPlayers, max))

    local room = { id = nextRoomId, name = name, host = src, private = opts.private == true, max = max, members = {},
                   mode = opts.mode == "solo" and "solo" or "team" }
    nextRoomId = nextRoomId + 1
    Rooms[room.id] = room
    local ok, err = addMember(room, src)
    if not ok then Rooms[room.id] = nil; return false, err end
    log(("room %d created by %s (%s, max %d%s)"):format(room.id, nameOf(src), name, max, room.private and ", private" or ""))
    return true, ("Created %s."):format(name)
end

local function joinRoom(src, id)
    local room = Rooms[tonumber(id) or -1]
    if not room then return false, "That room is gone." end
    if RoomOf[src] == room then return true end
    local b = busy(src)
    if b then return false, "You are " .. b .. "." end
    if room.round then return false, "That room is mid-round — wait for it to finish." end
    if room.private and not (Invites[src] and Invites[src][room.id]) then return false, "That room is invite-only." end
    if count(room.members) >= roomMax(room) then return false, "That room is full." end
    local ok, err = addMember(room, src)
    if not ok then return false, err end
    return true, ("Joined %s."):format(room.name)
end

-- Public matchmaking: the fullest open public room, else a new one.
local function quickJoin(src)
    local best
    for _, room in pairs(Rooms) do
        if not room.private and not room.round and count(room.members) < roomMax(room)
            and (not best or count(room.members) > count(best.members)) then
            best = room
        end
    end
    if best then return joinRoom(src, best.id) end
    return createRoom(src, {})
end

local function roomView(room, viewer)
    local roster = {}
    for s, e in pairs(room.members) do
        roster[#roster + 1] = { src = s, name = e.name, isMe = (s == viewer), host = (s == room.host) }
    end
    table.sort(roster, function(a, b)
        if a.host ~= b.host then return a.host end
        return a.name < b.name
    end)
    return {
        id = room.id, name = room.name, private = room.private, host = nameOf(room.host), mode = room.mode,
        count = #roster, max = roomMax(room), live = room.round ~= nil,
        armed = room.armed,
        armedRemain = room.armed and math.max(0, (Config.LobbyWaitSec or 45) - math.floor((GetGameTimer() - room.armedAt) / 1000)) or nil,
        roster = roster,
    }
end

-- Shape kept compatible with the old single-lobby menu (inLobby/count/roster…),
-- plus the room list for the hub.
local function lobbyStateFor(src)
    local room = RoomOf[src]
    local rooms = {}
    for _, rm in pairs(Rooms) do
        local invited = Invites[src] and Invites[src][rm.id] or false
        if not rm.private or invited or rm == room then
            local v = roomView(rm, src)
            v.roster, v.invited, v.mine = nil, invited and true or false, rm == room
            rooms[#rooms + 1] = v
        end
    end
    table.sort(rooms, function(a, b)
        if a.mine ~= b.mine then return a.mine end
        if a.invited ~= b.invited then return a.invited end
        if a.live ~= b.live then return not a.live end
        return a.count > b.count
    end)

    local v = room and roomView(room, src)
    return {
        rooms = rooms, maxRooms = Config.MaxRooms or 8,
        room = v, isHost = room ~= nil and room.host == src,
        inRound = roundOf(src) ~= nil,
        roundLive = v and v.live or false,
        inLobby = room ~= nil,
        count = v and v.count or 0, min = Config.MinPlayers, max = v and v.max or Config.MaxPlayers,
        armed = v and v.armed or false, armedRemain = v and v.armedRemain or nil,
        roster = v and v.roster or {},
    }
end

local function reply(src, ok, msg)
    if msg then notify(src, msg, ok and "success" or "error") end
    return lobbyStateFor(src)
end

local function toggleJoin(src)
    if RoomOf[src] then
        if roundOf(src) then notify(src, "You are in a round.", "error"); return end
        removeMember(src, "left")
        notify(src, "Left the room.")
        return
    end
    local ok, msg = quickJoin(src)
    if msg then notify(src, msg, ok and "success" or "error") end
end

local function startNow(src)
    local room = RoomOf[src]
    if not room then return false, "Join a room first with /" .. Config.Command end
    if room.host ~= src then return false, "Only the room host can start." end
    if room.round then return false, "A round is already running." end
    if count(room.members) < Config.MinPlayers then return false, ("Need %d players."):format(Config.MinPlayers) end
    CreateThread(function() startRound(room) end)
    return true
end

-- ── Commands / callbacks ────────────────────────────────────────────────────

RegisterCommand(Config.Command, function(source) if source > 0 then toggleJoin(source) end end, false)

RegisterCommand(Config.StartCommand, function(source)
    if source <= 0 then return end
    local ok, msg = startNow(source)
    if not ok then notify(source, msg, "error") end
end, false)

lib.callback.register(EV .. "lobbyState", function(src) return lobbyStateFor(src) end)
lib.callback.register(EV .. "joinToggle", function(src) toggleJoin(src); return lobbyStateFor(src) end)
lib.callback.register(EV .. "createRoom", function(src, opts) return reply(src, createRoom(src, opts)) end)
lib.callback.register(EV .. "joinRoom", function(src, id) return reply(src, joinRoom(src, id)) end)
lib.callback.register(EV .. "leaveRoom", function(src)
    if roundOf(src) then return reply(src, false, "You are in a round.") end
    if not RoomOf[src] then return reply(src, false) end
    removeMember(src, "left")
    return reply(src, true, "Left the room.")
end)
lib.callback.register(EV .. "startRoom", function(src) return reply(src, startNow(src)) end)
lib.callback.register(EV .. "kick", function(src, target)
    local room = RoomOf[src]
    target = tonumber(target)
    if not room or room.host ~= src then return reply(src, false, "Only the host can do that.") end
    if room.round then return reply(src, false, "Not during a round.") end
    if not target or target == src or RoomOf[target] ~= room then return reply(src, false) end
    removeMember(target, "removed by host")
    notify(target, ("You were removed from %s."):format(room.name), "warning")
    return reply(src, true)
end)

-- Online players eligible to invite: not already in a room.
lib.callback.register(EV .. "online", function(src)
    local list = {}
    for _, pid in ipairs(GetPlayers()) do
        local sid = tonumber(pid)
        if sid ~= src and not RoomOf[sid] and invitable(sid) then
            list[#list + 1] = { source = sid, name = nameOf(sid) }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end)

-- ── Invites ─────────────────────────────────────────────────────────────────

RegisterNetEvent(EV .. "invite", function(targetSrc)
    local src = source
    local room = RoomOf[src]
    targetSrc = tonumber(targetSrc)
    if not room then notify(src, "Join a room before inviting.", "error"); return end
    if not targetSrc or not GetPlayerName(targetSrc) then notify(src, "That player is not online.", "error"); return end
    if RoomOf[targetSrc] then notify(src, "They are already in a room.", "info"); return end
    if count(room.members) >= roomMax(room) then notify(src, "Room full.", "error"); return end

    Invites[targetSrc] = Invites[targetSrc] or {}
    Invites[targetSrc][room.id] = true
    Invites[targetSrc].last = room.id
    TriggerClientEvent(EV .. "invited", targetSrc, { fromSrc = src, fromName = room.members[src].name, room = room.id, roomName = room.name })
    notify(src, ("Invite sent to %s."):format(nameOf(targetSrc)), "success")
end)

RegisterNetEvent(EV .. "acceptInvite", function(roomId)
    local src = source
    if RoomOf[src] then return end
    local id = tonumber(roomId) or (Invites[src] and Invites[src].last)
    if not id then return end
    local ok, msg = joinRoom(src, id)
    if msg then notify(src, msg, ok and "success" or "error") end
end)

-- ── Round plumbing ──────────────────────────────────────────────────────────

-- Client is standing at its spawn with the platform built: NOW create its car.
-- Creating it here (player already nearby, in the bucket) means the player gets
-- ownership straight away and can drive it.
RegisterNetEvent(EV .. "ready", function()
    local src = source
    local r = roundOf(src)
    local p = r and r.players[src]
    if not p or p.veh or not p.spawn or p.onDeck then return end
    local veh = spawnCarFor(src, r.bucketId or 0, p.spawn.x, p.spawn.y, p.spawn.z, p.heading, p.model)
    if not r.active then if veh then DeleteEntity(veh) end return end
    p.veh = veh
    p.onDeck = true
    TriggerClientEvent(EV .. "car", src, { netId = veh and NetworkGetNetworkIdFromEntity(veh) or nil, model = p.model })
end)

-- "Leave minigame" from the Esc / radial menu. Counts as eliminated; they are
-- taken out of the round entirely so the end-of-round payout skips them.
RegisterNetEvent(EV .. "leave", function()
    local src = source
    local r = roundOf(src)
    local p = r and r.players[src]
    if p then
        deleteCar(p)
        setContact(src, false)
        r.players[src] = nil
        TriggerClientEvent(EV .. "over", src, { won = false, payout = 0, pushes = p.pushes or 0 })
        SetTimeout(600, function()
            if GetPlayerName(src) and GetResourceState("spz-core") == "started" then
                exports["spz-core"]:RemovePlayerFromBucket(src)
            end
        end)
        toAll(r, EV .. "feed", { name = p.name, why = "left" })
    end
    removeMember(src, "left")
end)

AddEventHandler("playerDropped", function()
    local src = source
    local r = roundOf(src)
    if r then
        local p = r.players[src]
        p.alive, p.left = false, true
        deleteCar(p)
    end
    removeMember(src, "disconnected")
    Invites[src] = nil
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, room in pairs(Rooms) do
        if room.round then endRound(room.round, "resource stopped") end
    end
end)
