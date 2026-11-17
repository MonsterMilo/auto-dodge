plugin = {
    name = "auto-dodge",
    displayName = "Auto Dodge",
    command = "dodge",
    prefix = "§bAD",
    version = "1.0.0",
    minStarfishVersion = "0.1.0-beta.16",
    description = "Dodges pregame lobbies when parties, open queues or nicks show up.",
    dependencies = {
        { name = "hypixel-mod-api" },
    },
}

-- Dodges BedWars pregame lobbies on the triggers below. It never acts after
-- a game ends, when your bed breaks, or when you aren't the party leader.
--
-- How the lobby is read:
-- * Pregame names are scrambled. Join lines that come within the Group gap
--   of each other are one party. A group bigger than a team is more than one
--   party, but still counts by its full size.
-- * Your own party comes from Hypixel's Mod API (who's in it, who leads).
--   Party members show their real names in tab, so they're never counted.
-- * Nicks: a nick's join line name doesn't match its tab name. Every pregame
--   player gets a random ID, so players already there can't be checked.
-- * A split party is only reported, never dodged: a nicked member who got
--   in first looks like anyone else.
-- * Nothing is sent in the last 2s before the game starts.

-- Constants

local CUTOFF_MS = 2000          -- nothing is sent this close to the start
local CHECK_MS = 2000           -- no server change this long after a dodge: try again
local RETRY_MS = 3000
local PLAY_EXTRA_MS = 2000      -- /play takes longer to move you than /l
local SENDING_WAIT_MS = 5000    -- "Sending you to ...": give it this long
local TRIES = 3
-- Hypixel's command rate limit, from testing:
-- "Woah there, slow down!" IS the /l cooldown. It came when a command went
-- out 1.5-2s after the one before, and any command counts (/pc too). Every
-- command sent while it's on starts it again, so nothing is sent until it's
-- had 6s (5s wasn't always enough). /hub shares the cooldown, so retries only
-- ever resend the same command.
local SLOW_DOWN_MS = 6000
local COMMAND_SPACING_MS = 2500 -- a dodge waits this long after your last command
local SLOW_DOWN_TRIES = 3
local COOLDOWN_MS = 1500
local COOLDOWN_EXTRA_MS = 500
local PARTY_WAIT_MS = 2000      -- your party has this long after your join line to arrive
local READY_WAIT_MS = 1500      -- how long your join waits for the Mod API's party and location
local WITH_YOU_MS = 45          -- join lines this close to yours came in with you
local NICK_BEFORE_MS = 600      -- a nick's tab entry lands this close to its join line
local NICK_AFTER_MS = 300
local NOTICE_DELAY_MS = 500     -- party chat goes after the dodge command
local ROW_RESET_MS = 15 * 60 * 1000
local LOG_MAX = 20
local QUIT_GAP_MS = 400        -- a party's quit lines are further apart than its joins
local DEFAULT_GAP = 100
local MIN_GAP, MAX_GAP = 10, 1000

local START_TEXTS = {
    ["Protect your bed and destroy the enemy beds."] = true,
}
local START_PHRASE = "powerful upgrades"
local TEAM_WORDS = { ONE = 1, TWO = 2, THREE = 3, FOUR = 4 }

local function cycle(values)
    local out = {}
    for i, v in ipairs(values) do out[i] = { text = v[1], value = v[2] } end
    return out
end

local GAP_VALUES = cycle({
    { "50ms", 50 }, { "75ms", 75 }, { "100ms", 100 }, { "150ms", 150 }, { "200ms", 200 },
    { "250ms", 250 }, { "300ms", 300 }, { "400ms", 400 }, { "500ms", 500 },
})

local SIZE_VALUES = cycle({ { "1+", 1 }, { "2+", 2 }, { "3+", 3 }, { "4+", 4 } })

-- Config (in game, each section's first switch is its [+]/[-] header)

starfish.schema.section({
    key = "partyDodge",
    label = "Party Dodge",
    description = "Dodge parties that join.",
    settings = {
        { key = "partyDodge.on", type = "toggle", default = true, label = "Party Dodge", description = "Dodge parties that join." },
        { key = "partyDodge.size", type = "cycle", default = 3, label = "Size", description = "Smallest party to dodge.", values = cycle({
            { "2+", 2 }, { "3+", 3 }, { "4+", 4 },
        }) },
        { key = "partyDodge.gap", type = "cycle", default = DEFAULT_GAP, label = "Gap", description = "Join lines closer than this are one party.", values = GAP_VALUES },
    },
})

starfish.schema.section({
    key = "openDodge",
    label = "Open Queue Dodge",
    description = "Dodge lobbies that already had players.",
    settings = {
        { key = "openDodge.on", type = "toggle", default = false, label = "Open Queue Dodge", description = "Dodge lobbies that already had players." },
        { key = "openDodge.players", type = "cycle", default = 2, label = "Players", description = "Players already there.", values = SIZE_VALUES },
    },
})

starfish.schema.section({
    key = "nickDodge",
    label = "Nick Dodge",
    description = "Dodge lobbies with nicks.",
    settings = {
        { key = "nickDodge.on", type = "toggle", default = false, label = "Nick Dodge", description = "Dodge lobbies with nicks." },
        { key = "nickDodge.nicks", type = "cycle", default = 1, label = "Nicks", description = "Nicks in the lobby.", values = SIZE_VALUES },
    },
})

starfish.schema.section({
    key = "settings",
    label = "Dodge Settings",
    settings = {
        { key = "settings.method", type = "cycle", default = "lobby", label = "Dodge With", description = "/l goes to the lobby. /play joins a new game.", values = cycle({
            { "/l", "lobby" }, { "/play", "play" },
        }) },
        { key = "settings.sound", type = "soundToggle", default = true, label = "Sound", description = "Plays a sound on dodge." },
        { key = "settings.count", type = "toggle", default = true, label = "Dodge Count", description = "Says how many dodges a game took." },
    },
})

starfish.schema.section({
    key = "alerts",
    label = "Join Alerts",
    description = "Shows parties and nicks joining.",
    settings = {
        { key = "alerts.joins", type = "toggle", default = true, label = "Join Alerts", description = "Shows parties that join." },
        { key = "alerts.leaves", type = "toggle", default = true, label = "Leaves", description = "Shows parties that leave." },
        { key = "alerts.nicks", type = "toggle", default = true, label = "Nicks", description = "Shows nicks that join." },
        { key = "alerts.split", type = "toggle", default = true, label = "Split", description = "Shows when your party may be split." },
    },
})

starfish.schema.section({
    key = "partyChat",
    label = "Party Chat",
    description = "Tells your party about dodges and splits.",
    settings = {
        { key = "partyChat.on", type = "toggle", default = false, label = "Party Chat", description = "Tells your party about dodges." },
        { key = "partyChat.reason", type = "toggle", default = true, label = "Reason", description = "Says why you dodged." },
        { key = "partyChat.count", type = "toggle", default = true, label = "Count", description = "Says how many dodges a game took." },
        { key = "partyChat.split", type = "toggle", default = true, label = "Split", description = "Says when your party may be split." },
    },
})

starfish.config.defaults({ customGap = 0 })

-- State

local location = { server = nil, mode = nil, inGame = false, known = false }
local party = { known = false, stale = false, pending = false, askedAt = 0, inParty = false, size = 1, leader = true, uuids = {} }
local row = { count = 0, firstAt = 0, lastAt = 0 }
local send = { slowUntil = 0, lastCommandAt = -1e9, timer = nil, next = nil, tries = 0, slowTries = 0, note = nil }
local history = {}
local lobby
local lobbySerial = 0

local function now() return starfish.time.monotonic() end
local function cfg(key) return starfish.config.get(key) end

local function newLobby()
    lobbySerial = lobbySerial + 1
    return {
        id = lobbySerial,
        enteredAt = now(),
        joins = {},        -- { name, lower, at }
        joinNames = {},    -- lower -> true
        burst = {},
        burstTimer = nil,
        quits = 0,
        quitTimer = nil,
        tabAdds = {},      -- { uuid, lower, at }
        count = 0, max = 0,
        mySeen = false, myAt = 0, before = 0,
        mineDone = false, mineWaiting = false, laterBursts = {},
        nicks = {},        -- uuid -> true (nicked players spotted)
        partyNicks = {},   -- uuid -> true (your party's nicked members)
        usedTab = {},      -- uuid -> true (tab entries already paired with a join line)
        partyWait = nil,
        startAt = 0,
        started = false,
        acted = false,
        result = nil,      -- "sent" while a dodge is going
    }
end

lobby = newLobby()

-- Helpers

local function plain(text) return starfish.text.plain(text or "") end
local function lower(text) return plain(text):lower() end
local function normUuid(uuid) return uuid and (tostring(uuid):gsub("-", ""):lower()) or nil end

local function countText()
    if lobby.max > 0 then return " §8(" .. lobby.count .. "/" .. lobby.max .. ")" end
    return ""
end

local function gap()
    local custom = tonumber(cfg("customGap")) or 0
    if custom >= MIN_GAP and custom <= MAX_GAP then return custom end
    local v = tonumber(cfg("partyDodge.gap")) or DEFAULT_GAP
    return (v >= MIN_GAP and v <= MAX_GAP) and v or DEFAULT_GAP
end

local function teamSize()
    local mode = location.mode and location.mode:upper() or ""
    local third = mode:match("^BEDWARS_%u+_(%u+)")
    return TEAM_WORDS[third or ""] or 4
end

local function playMode()
    return location.mode and location.mode:lower() or nil
end

local function meInfo()
    local me = starfish.players.me()
    if not me then return nil, nil end
    local id = normUuid(me.uuid)
    for _, p in ipairs(starfish.players.all()) do
        if normUuid(p.uuid) == id then return id, lower(p.name) end
    end
    return id, me.name and me.name:lower() or nil
end

local function myName()
    local _, name = meInfo()
    return name or ""
end

local function timeLeft()
    if lobby.startAt > 0 then return lobby.startAt - now() end
    return math.huge
end

-- The tab list right now: lower name -> uuid, and the uuids present.
local function tabNow()
    local byName, present = {}, {}
    for _, p in ipairs(starfish.players.all()) do
        local id = normUuid(p.uuid)
        if id then
            byName[lower(p.name)] = id
            present[id] = true
        end
    end
    return byName, present
end

-- Party members' tab names (they show real names in pregame).
local function partyTabNames()
    local names, myId = {}, (meInfo())
    for _, p in ipairs(starfish.players.all()) do
        local id = normUuid(p.uuid)
        if id and id ~= myId and party.uuids[id] then names[lower(p.name)] = id end
    end
    return names
end

local function joinedAt(name)
    for i = #lobby.joins, 1, -1 do
        if lobby.joins[i].name == name then return lobby.joins[i].at end
    end
    return 0
end

-- Messages

local function say(text)
    starfish.chat.info(starfish.text.of(text))
end

-- Party chat, NOTICE_DELAY_MS after any dodge command and never during a slow down.
local function partyChat(text, kind)
    if not cfg("partyChat.on") or not cfg("partyChat." .. kind) or not party.inParty or party.size < 2 then return end
    starfish.timers.delay(NOTICE_DELAY_MS, function()
        if now() < send.slowUntil then return end
        send.lastCommandAt = now()
        starfish.chat.sendToServer("/pc " .. text)
    end)
end

local function logEntry(kind, what)
    table.insert(history, 1, { at = starfish.time.now(), kind = kind, what = what, result = "sent" })
    while #history > LOG_MAX do table.remove(history) end
end

local function setResult(result)
    if history[1] and history[1].result == "sent" then history[1].result = result end
end

-- Sending

local function cancelSend()
    if send.timer then send.timer:off() end
    send.timer = nil
    send.next = nil
    send.note = nil
end

local function command()
    local mode = playMode()
    if cfg("settings.method") == "play" and mode then return "/play " .. mode end
    return "/l"
end

local sendDodge

local function failed(text)
    setResult("failed")
    lobby.result = nil
    say(text)
end

sendDodge = function(tries, note)
    if lobby.started then return end
    cancelSend()
    send.note = note
    local id = lobby.id
    -- Slow down on, or too soon after your last command: wait it out, so
    -- the dodge doesn't start the cooldown (and cost 6s).
    local slow = math.max(send.slowUntil - now(), send.lastCommandAt + COMMAND_SPACING_MS - now())
    if slow > 0 then
        send.timer = starfish.timers.delay(slow, function()
            send.timer = nil
            if lobby.id ~= id or lobby.started then return end
            if timeLeft() < CUTOFF_MS then return failed("§cDodge failed §8· §7too late") end
            sendDodge(tries, note)
        end)
        return
    end
    send.lastCommandAt = now()
    starfish.chat.sendToServer(command())
    send.tries = tries
    if send.note then
        partyChat(send.note, "reason")
        send.note = nil
    end
    send.next = function()
        send.next = nil
        if lobby.id ~= id or lobby.started then return end
        if tries >= TRIES then return failed("§cDodge failed §8· §7" .. TRIES .. " tries") end
        if timeLeft() < CUTOFF_MS then return failed("§cDodge failed §8· §7too late") end
        say("§7Retrying §8(" .. (tries + 1) .. "/" .. TRIES .. ")")
        sendDodge(tries + 1)
    end
    local wait = tries == 1 and CHECK_MS or RETRY_MS
    if command() ~= "/l" then wait = wait + PLAY_EXTRA_MS end
    send.timer = starfish.timers.delay(wait, function()
        send.timer = nil
        if send.next then send.next() end
    end)
end

-- Every trigger ends here. what: the chat line, note: the party chat line.
local function dodge(kind, what, note, noCount)
    if lobby.acted or lobby.started then return false end
    if teamSize() < 2 then return false end   -- solos never dodge
    if party.inParty and not party.leader then return false end
    lobby.acted = true
    local line = what .. (noCount and "" or countText())
    if timeLeft() < CUTOFF_MS then
        say(line .. " §8· §7too late")
        return false
    end
    say("§cDodging §8» §r" .. line)
    logEntry(kind, plain(line))
    lobby.result = "sent"
    sendDodge(1, "Dodging: " .. note)
    return true
end

-- Triggers

local function lobbyNickCount()
    local _, present = tabNow()
    local n = 0
    for id in pairs(lobby.nicks) do
        if present[id] and not lobby.partyNicks[id] then n = n + 1 end
    end
    -- While your party isn't all here, its missing members may be nicks.
    local wait = lobby.partyWait
    if wait and wait.missing > 0 then n = n - wait.missing end
    return math.max(0, n)
end

local function nickCheck()
    if not lobby.mineDone or lobby.acted or lobby.started then return end
    if not cfg("nickDodge.on") then return end
    local min = tonumber(cfg("nickDodge.nicks")) or 1
    local n = lobbyNickCount()
    if n < min then return end
    local what = n == 1 and "§c1 nick" or ("§c" .. n .. " nicks")
    dodge("nick", what, n == 1 and "a nick is in the lobby" or (n .. " nicks in the lobby"))
end

-- Is this join line a nick? Returns the nick's tab uuid, or nil.
local function nickOf(name, byName)
    local l = name:lower()
    if byName[l] then return nil end
    -- Not in tab under its join name: a nick, if a tab entry no join line
    -- names was added right around it.
    local at = joinedAt(name)
    if at == 0 then return nil end
    local myId = meInfo()
    for _, t in ipairs(lobby.tabAdds) do
        if t.at >= at - NICK_BEFORE_MS and t.at <= at + NICK_AFTER_MS and not lobby.usedTab[t.uuid]
            and not lobby.joinNames[t.lower] and byName[t.lower] == t.uuid
            and t.uuid ~= myId and not party.uuids[t.uuid] then
            lobby.usedTab[t.uuid] = true
            return t.uuid
        end
    end
    return nil
end

local function markNicks(names, ofParty)
    local byName = tabNow()
    local found = 0
    for _, n in ipairs(names) do
        local id = nickOf(n, byName)
        if id then
            lobby.nicks[id] = true
            if ofParty then lobby.partyNicks[id] = true end
            found = found + 1
        end
    end
    return found
end

local function partyCheck(size, crowd)
    if lobby.acted or lobby.started or size < 2 then return end
    local team = teamSize()
    if team < 2 or not cfg("partyDodge.on") then return end
    if size < (tonumber(cfg("partyDodge.size")) or 3) then return end
    local what = crowd and ("§b" .. size .. " §7at once") or ("§7Party of §b" .. size)
    local note = crowd and (size .. " joined at once") or ("party of " .. size .. " joined")
    dodge("party", what, note)
end

local function openCheck(waiting, atLeast)
    if lobby.acted or lobby.started or waiting < 1 then return end
    if not cfg("openDodge.on") then return end
    if waiting < (tonumber(cfg("openDodge.players")) or 2) then return end
    local n = waiting .. (atLeast and "+" or "")
    dodge("open", "§b" .. n .. " §7waiting", n .. " already in the lobby")
end

-- Groups

local function addOthers(names)
    if lobby.started or #names == 0 then return end
    -- Your party's late members (named ones, or one lone unnamed name) join your group.
    local wait = lobby.partyWait
    if wait and wait.missing > 0 and now() <= wait.untilAt then
        local partyNames = partyTabNames()
        local take, rest = {}, {}
        for _, n in ipairs(names) do
            if partyNames[n:lower()] and #take < wait.missing then table.insert(take, n) else table.insert(rest, n) end
        end
        local room = wait.missing - #take
        if room > 0 and #rest > 0 and #rest <= room and (#take > 0 or #rest == 1) then
            for _, n in ipairs(rest) do table.insert(take, n) end
            rest = {}
        end
        if #take > 0 then
            wait.missing = wait.missing - #take
            markNicks(take, true)
            if wait.missing < 1 then
                if wait.timer then wait.timer:off() end
                lobby.partyWait = nil
            end
        end
        names = rest
    end
    if #names == 0 then return end
    local nicks = markNicks(names, false)
    local team = teamSize()
    local crowd = team > 1 and #names > team
    partyCheck(#names, crowd)
    nickCheck()
    if lobby.acted then return end
    -- Join alerts
    local nickNote = (nicks > 0 and cfg("alerts.nicks")) and (" §8· §c" .. (nicks == 1 and "1 nick" or (nicks .. " nicks"))) or ""
    if #names >= 2 and team > 1 and cfg("alerts.joins") then
        local what = crowd and ("§b" .. #names .. " §7joined at once") or ("§7Party of §b" .. #names .. " §7joined")
        say("§8» " .. what .. countText() .. nickNote)
    elseif nicks > 0 and cfg("alerts.nicks") then
        local what = nicks == 1 and "§cA nick §7joined" or ("§c" .. nicks .. " nicks §7joined")
        say("§8» " .. what .. countText())
    end
end

-- Your party isn't all here PARTY_WAIT_MS after your line: a line and/or
-- party chat, never a dodge.
local function splitCheck()
    local wait = lobby.partyWait
    lobby.partyWait = nil
    if not wait or wait.missing < 1 or lobby.started or lobby.acted then return end
    nickCheck()   -- (nicks were held back while your party might still arrive)
    if lobby.acted then return end
    -- Count again now: a member who got here before you can show in tab late.
    local _, present = tabNow()
    local inTab = 0
    for id in pairs(party.uuids) do if present[id] then inTab = inTab + 1 end end
    local missing = math.min(wait.missing, party.size - 1 - inTab)
    if missing < 1 then return end
    local here = (party.size - missing) .. "/" .. party.size
    -- A nicked member who got here before you has no join line and a hidden
    -- name, so anyone already here could be them.
    local maybe = lobby.before >= missing
    local text = maybe and "Party might be split" or "Party split"
    if cfg("alerts.split") then say("§e" .. text .. " §8(" .. here .. ")") end
    if not party.leader then return end   -- one party message, from the leader
    partyChat(text .. " (" .. here .. " here)", "split")
end

-- Your join line's burst: you, your party, and anyone else.
local function splitMine(names)
    if lobby.started then return end
    local me = myName()
    local partyNames = partyTabNames()
    local byName = tabNow()
    local named, rest = {}, {}
    local inBurst = {}
    for _, n in ipairs(names) do
        local l = n:lower()
        inBurst[l] = true
        if l ~= me then
            if partyNames[l] then table.insert(named, n) else table.insert(rest, n) end
        end
    end
    -- Party members already here (no join line, real name in tab).
    local here = 0
    for l in pairs(partyNames) do
        if not inBurst[l] and byName[l] then here = here + 1 end
    end
    local team = teamSize()
    local more
    if party.known then
        more = math.max(0, party.size - 1 - #named - here)
    else
        -- No party answer: whoever came in right with you is taken as yours.
        local order = {}
        for _, n in ipairs(rest) do table.insert(order, { n = n, at = joinedAt(n) }) end
        table.sort(order, function(a, b) return a.at < b.at end)
        more = 0
        local last = lobby.myAt
        for _, x in ipairs(order) do
            if x.at - last > WITH_YOU_MS or more >= team - 1 then break end
            more = more + 1
            last = x.at
        end
    end
    local mine = {}
    for _, n in ipairs(named) do table.insert(mine, n) end
    for i = 1, math.min(more, #rest) do table.insert(mine, rest[i]) end
    local strangers = {}
    for i = more + 1, #rest do table.insert(strangers, rest[i]) end
    markNicks(mine, true)
    lobby.mineDone = true

    -- Open queue: everyone here before you, minus your party (a full team when
    -- the party is unknown, so your party is never an open queue).
    local partyBefore = math.max(here, (party.known and party.size or teamSize()) - 1 - #mine)
    openCheck(math.max(0, lobby.before - partyBefore), false)

    -- Your party isn't all here: the rest has until PARTY_WAIT_MS after your line.
    local missing = more - math.min(more, #rest)
    if party.known and missing > 0 then
        local untilAt = lobby.myAt + PARTY_WAIT_MS
        local id = lobby.id
        lobby.partyWait = { missing = missing, untilAt = untilAt }
        lobby.partyWait.timer = starfish.timers.delay(math.max(0, untilAt - now()), function()
            if lobby.id == id then splitCheck() end
        end)
    end

    if not lobby.acted and #mine >= 1 and teamSize() > 1 and cfg("alerts.joins") then
        say("§8» §7Your party of §b" .. (#mine + 1) .. " §7joined" .. countText())
    end
    if #strangers > 0 then addOthers(strangers) end
end

local function flushJoins()
    lobby.burstTimer = nil
    local names = lobby.burst
    lobby.burst = {}
    if #names == 0 or lobby.started then return end
    local me = myName()
    local hasMe = false
    for _, n in ipairs(names) do if n:lower() == me then hasMe = true end end
    if not hasMe then
        if lobby.mineWaiting then table.insert(lobby.laterBursts, names); return end
        if not lobby.mineDone then return end   -- (before your own line: not this lobby's yet)
        return addOthers(names)
    end
    local function go()
        lobby.mineWaiting = false
        -- (Not a BedWars game after all: nothing to do here.)
        if location.known and not location.inGame then return end
        splitMine(names)
        local later = lobby.laterBursts
        lobby.laterBursts = {}
        for _, b in ipairs(later) do addOthers(b) end
    end
    -- Wait for the Mod API's party answer and location (they can land after
    -- your line), up to READY_WAIT_MS.
    local function ready() return not party.pending and location.known end
    if ready() then return go() end
    lobby.mineWaiting = true
    local id = lobby.id
    local done = false
    local sub
    local function finish()
        if done or lobby.id ~= id then return end
        done = true
        if sub then sub:off() end
        go()
    end
    local timeout = starfish.timers.delay(READY_WAIT_MS, finish)
    sub = starfish.events.on("auto-dodge:ready", function()
        if ready() then timeout:off(); finish() end
    end)
end

-- Open queue at your own line: no waiting when it's already open even if
-- everyone else here were your party.
-- (Only with a party answer that's still current; otherwise splitMine checks
-- once the new answer is in.)
local function openEarly()
    if not cfg("openDodge.on") or not location.inGame or not party.known or party.stale then return end
    local min = tonumber(cfg("openDodge.players")) or 2
    local mates = party.size - 1
    local strangers = lobby.before - mates
    if strangers >= min then openCheck(strangers, mates > 0) end
end

-- Chat

local askParty

local function onJoinLine(name, n, max)
    lobby.count = n
    lobby.max = max
    local at = now()
    table.insert(lobby.joins, { name = name, lower = name:lower(), at = at })
    lobby.joinNames[name:lower()] = true
    table.insert(lobby.burst, name)
    if not lobby.mySeen and name:lower() == myName() then
        lobby.mySeen = true
        lobby.myAt = at
        lobby.before = math.max(0, n - 1)
        -- Fresh party info for every lobby: the location can land after your
        -- line, and the party may have changed since the last answer.
        askParty()
        openEarly()
    end
    if lobby.burstTimer then lobby.burstTimer:off() end
    lobby.burstTimer = starfish.timers.delay(gap(), flushJoins)
end

local function flushQuits()
    lobby.quitTimer = nil
    local n = lobby.quits
    lobby.quits = 0
    if n < 2 or lobby.acted or lobby.started or teamSize() < 2 or not cfg("alerts.leaves") then return end
    say("§8« §7Party of §3" .. n .. " §7left" .. countText())
end

local function onQuitLine()
    lobby.count = math.max(0, lobby.count - 1)
    if not lobby.mySeen then return end
    lobby.quits = lobby.quits + 1
    if lobby.quitTimer then lobby.quitTimer:off() end
    lobby.quitTimer = starfish.timers.delay(math.max(gap(), QUIT_GAP_MS), flushQuits)
end

local function cooldownWait(text)
    local secs = text:match("in (%d+%.?%d*) seconds?")
    local ms = secs and tonumber(secs) * 1000 or (text:lower():find("about a second") and 1000 or COOLDOWN_MS)
    return ms + COOLDOWN_EXTRA_MS
end

local function isCooldown(text)
    local l = text:lower()
    return l:find("^command failed: this command is on cooldown") or l:find("^you are sending commands too fast")
        or l:find("^please slow down") or l == "slow down" or l == "slow down!"
end

local function onSlowDown()
    send.slowUntil = now() + SLOW_DOWN_MS
    if not send.next or lobby.started then return end
    local tries = send.tries
    cancelSend()
    send.slowTries = send.slowTries + 1
    if send.slowTries > SLOW_DOWN_TRIES then
        return failed("§cDodge failed §8· §7slowed down")
    end
    say("§7Slowed down §8· §7retrying in " .. math.floor(SLOW_DOWN_MS / 1000) .. "s")
    sendDodge(tries)
end

local function onGameStart()
    if lobby.started then return end
    lobby.started = true
    if lobby.burstTimer then lobby.burstTimer:off(); lobby.burstTimer = nil end
    if lobby.result == "sent" then failed("§cDodge failed §8· §7game started") end
    cancelSend()
    if lobby.partyWait and lobby.partyWait.timer then lobby.partyWait.timer:off() end
    lobby.partyWait = nil
    local n = (now() - row.lastAt <= ROW_RESET_MS) and row.count or 0
    local secs = math.max(0, math.floor((now() - row.firstAt) / 1000))
    row.count = 0
    if n < 1 then return end
    local took = secs .. "s"
    if secs >= 60 then took = math.floor(secs / 60) .. "m" .. (secs % 60 > 0 and (" " .. (secs % 60) .. "s") or "") end
    local dodges = n .. " dodge" .. (n == 1 and "" or "s")
    if cfg("settings.count") then say("§aFound a game §8· §7" .. dodges .. ", " .. took) end
    partyChat("Found a game after " .. dodges .. " (" .. took .. ")", "count")
end

starfish.events.on("chat:receive", function(event)
    if event.kind == "actionBar" then return end
    local text = plain(event.message):match("^%s*(.-)%s*$")
    if text:lower():find("^woah there, slow down") then return onSlowDown() end
    -- Your party changed: the last answer is out of date until the next one.
    if not text:find(":", 1, true) and (text:find(" the party[%.!]") or text:find("'s party!$")
        or text:find("^The party was disbanded") or text:find("^You left the party")) then
        party.stale = true
    end
    -- (Until the Mod API says where you are, join lines are trusted: they only
    -- show in pregame lobbies, and the location can land after your own.)
    if (location.known and not location.inGame) or lobby.started then return end
    if send.next and isCooldown(text) then
        local next = send.next
        if send.timer then send.timer:off() end
        send.timer = starfish.timers.delay(cooldownWait(text), function()
            send.timer = nil
            if send.next == next then next() end
        end)
        return
    end
    if send.next and text:find("^Sending you to ") then
        local next = send.next
        if send.timer then send.timer:off() end
        send.timer = starfish.timers.delay(SENDING_WAIT_MS, function()
            send.timer = nil
            if send.next == next then next() end
        end)
        return
    end
    if START_TEXTS[text] or (text:find(START_PHRASE, 1, true) and not text:find(":", 1, true)) then
        return onGameStart()
    end
    local secs = text:match("^The game starts in (%d+) seconds?!$")
    if secs then lobby.startAt = now() + tonumber(secs) * 1000; return end
    if text:find("Start cancelled", 1, true) and not text:find(":", 1, true) then lobby.startAt = 0; return end
    local name, n, max = text:match("^(%S+) has joined %((%d+)/(%d+)%)!$")
    if name then return onJoinLine(name, tonumber(n), tonumber(max)) end
    if text:match("^%S+ has quit!$") then return onQuitLine() end
end)

-- Your own commands count toward Hypixel's rate limit too.
starfish.events.on("chat:send", function(event)
    local m = event and event.message
    if type(m) == "string" and m:sub(1, 1) == "/" then send.lastCommandAt = now() end
end)

-- Tab list: when each entry was added (pairs a nick's join line with its entry).
starfish.events.on("player:join", function(event)
    local id = normUuid(event.uuid)
    if not id or lobby.started then return end
    table.insert(lobby.tabAdds, { uuid = id, lower = lower(event.name), at = now() })
    if #lobby.tabAdds > 200 then table.remove(lobby.tabAdds, 1) end
end)

-- Party (Hypixel Mod API)

askParty = function()
    if party.pending and now() - party.askedAt < READY_WAIT_MS then return end
    party.askedAt = now()
    party.pending = true
    local ok = pcall(function() starfish.plugins.require("hypixel-mod-api").requestPartyInfo() end)
    if not ok then party.pending = false end
end

starfish.events.on("hypixel:party_info", function(result)
    party.pending = false
    if result and result.success then
        party.known = true
        party.stale = false
        party.inParty = result.inParty == true
        party.uuids = {}
        party.size = 1
        party.leader = true
        if party.inParty then
            local myId = meInfo()
            party.size = #(result.members or {})
            for _, m in ipairs(result.members or {}) do
                local id = normUuid(m.uuid)
                if id then
                    party.uuids[id] = true
                    if id == myId then party.leader = m.role == "LEADER" end
                end
            end
            if myId then party.uuids[myId] = nil end
            party.size = math.max(1, party.size)
        end
    else
        party.known = false
    end
    starfish.events.emit("auto-dodge:ready", {})
end)

-- Where you are

-- The dodge sound plays once the next server has placed you (its first
-- position for you): one played before the world change gets cut off.
local SOUND_SETTLE_MS = 100     -- lets the client finish loading the new world
local SOUND_FALLBACK_MS = 2000  -- no position by then: play anyway
local soundWait = nil
local function playDodgeSound(pos)
    soundWait = nil
    starfish.client.world.playSound("note.pling", { volume = 1.0, pitch = 0.8, position = pos })
end
local function dodgeSound()
    if not cfg("settings.sound") then return end
    local token = {}
    soundWait = token
    starfish.timers.delay(SOUND_FALLBACK_MS, function()
        if soundWait == token then playDodgeSound(nil) end
    end)
end
starfish.events.on("player:positionUpdate", function(event)
    local token = soundWait
    if not token then return end
    soundWait = false
    local pos = event and event.x and { x = event.x, y = event.y, z = event.z } or nil
    starfish.timers.delay(SOUND_SETTLE_MS, function()
        if soundWait == false then playDodgeSound(pos) end
    end)
end)

local function newServer()
    if lobby.result == "sent" then
        setResult("left")
        dodgeSound()
        if now() - row.lastAt > ROW_RESET_MS then row.count = 0 end
        if row.count == 0 then row.firstAt = lobby.enteredAt end
        row.count = row.count + 1
        row.lastAt = now()
    end
    cancelSend()
    send.slowTries = 0
    if lobby.burstTimer then lobby.burstTimer:off() end
    if lobby.quitTimer then lobby.quitTimer:off() end
    if lobby.partyWait and lobby.partyWait.timer then lobby.partyWait.timer:off() end
    lobby = newLobby()
end

local function applyLocation(loc)
    if loc.serverName and location.server and loc.serverName ~= location.server and lobby.mySeen then
        newServer()
    end
    location.server = loc.serverName
    location.mode = loc.mode
    location.inGame = loc.serverType == "BEDWARS" and loc.lobbyName == nil and loc.mode ~= nil
    location.known = true
    if location.inGame then askParty() end
    starfish.events.emit("auto-dodge:ready", {})
end

starfish.events.on("hypixel:location", function(event)
    if event.success and event.location then applyLocation(event.location) end
end)

starfish.events.on("world:respawn", function()
    newServer()
    location.known = false
    location.server = nil   -- (the next location is this new server's, not a move)
end)
starfish.events.on("session:join", function()
    newServer()
    location.known = false
    location.server = nil
    location.inGame = false
    party.known = false
end)

starfish.config.onChange("partyDodge.gap", function()
    starfish.config.set("customGap", 0)
end)

-- Commands

local function status()
    local function level(on, key, fallback)
        return cfg(on) and ("§f" .. (tonumber(cfg(key)) or fallback) .. "+") or "§coff"
    end
    local lines = {
        "§bAuto Dodge §8· §7with §f" .. (cfg("settings.method") == "play" and "/play" or "/l"),
        "§7Parties: " .. level("partyDodge.on", "partyDodge.size", 3)
            .. " §8· §7Gap: §f" .. gap() .. "ms",
        "§7Open queue: " .. level("openDodge.on", "openDodge.players", 2) .. " §8· §7Nicks: " .. level("nickDodge.on", "nickDodge.nicks", 1),
        "§7Party: §f" .. (party.known and (party.inParty and (party.size .. (party.leader and " (leader)" or " (member)")) or "none") or "unknown")
            .. " §8· §7In a row: §f" .. row.count,
    }
    return starfish.ui.lines(lines)
end

starfish.commands.register("status", { description = "Show what's on", default = true }, function()
    return status()
end)

starfish.commands.register("gap", {
    description = "Show or set the group gap (10-1000 ms)",
    arguments = { { name = "ms", type = "int", optional = true } },
}, function(ctx)
    local ms = ctx.args.ms
    if not ms then return "§7Group gap: §f" .. gap() .. "ms" end
    if ms < MIN_GAP or ms > MAX_GAP then return "§cUse " .. MIN_GAP .. " to " .. MAX_GAP .. ", like /dodge gap 150" end
    local listed = false
    for _, v in ipairs(GAP_VALUES) do if v.value == ms then listed = true end end
    if listed then
        starfish.config.set("partyDodge.gap", ms)
        starfish.config.set("customGap", 0)
    else
        starfish.config.set("customGap", ms)
    end
    return "§7Group gap set to §f" .. ms .. "ms"
end)

starfish.commands.register("log", { description = "Recent dodges" }, function()
    if #history == 0 then return "§7No dodges yet this session." end
    local lines = {}
    local t = starfish.time.now()
    for _, h in ipairs(history) do
        local ago = math.floor((t - h.at) / 1000)
        local when = ago >= 60 and (math.floor(ago / 60) .. "m") or (ago .. "s")
        local mark = h.result == "left" and "§a✔" or (h.result == "failed" and "§c✘" or "§e…")
        table.insert(lines, mark .. " §8" .. when .. " ago §7" .. h.what)
    end
    return starfish.ui.lines(lines)
end)

-- Exports

starfish.plugin.export("history", function() return history end)

-- Startup

local ok, restored = pcall(function() return starfish.plugins.require("hypixel-mod-api").getLocation() end)
if ok and restored and restored.serverName then applyLocation(restored) end
