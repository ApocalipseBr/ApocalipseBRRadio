if isClient() then return end
require "ApocalipseBRRadio/ABRRadioMusic"
require "ApocalipseBRRadio/ABRRadioServer"

-- Independent of ABR's game-minute scheduler: audio runs in real seconds.
ABRRadioMusicServer = { states = {}, sequence = getTimestampMs(), ready = false,
    scanIndex = 1, fastStations = 0 }
local S, M = ABRRadioMusicServer, ABRRadio.music
S.queues = {}
S.notices = {}
S.dedications = {}
S.announcerQueues = {}
S.MESSAGE_REPEATS = 5
S.MAX_QUEUE = 100
S.MAX_BATCH = 25
S.ANNOUNCER_INTERVAL = 3
S.MIN_ANNOUNCER_INTERVAL = 0.5
S.waitTicks = M.SCAN_WAIT_TICKS
S.LOG_INTERVAL_MS = 60000

local function stationLabel(station)
    return ABRRadio.resolveText(station.name) .. " [" .. station.id .. "] @ " .. station.frequency
end

local function logRuntime(station, state, now)
    local status = state.entry and state.phase or state.waitReason or "idle"
    if status == state.loggedStatus and state.loggedAt
        and now - state.loggedAt < S.LOG_INTERVAL_MS then return end
    state.loggedStatus, state.loggedAt = status, now
    local entry = state.entry
    local content = entry and ("; " .. entry.kind .. "=" .. entry.id
        .. "; caption=" .. M.caption(entry)
        .. "; elapsed=" .. string.format("%.1f/%.1fs", state.elapsed, entry.duration)) or ""
    print("[ABRRadio Music Server] Runtime: " .. stationLabel(station)
        .. "; state=" .. status .. "; songs=" .. #station.songs
        .. "; talks=" .. #station.talks .. content)
end

local function broadcast(station, state, announcement, lineText)
    local packet = { id = state.entry.id, sequence = state.sequence, phase = state.phase }
    if isServer() then
        sendServerCommand(ABRRadio.NET_MODULE, "MusicState", packet)
    elseif ABRRadioMusicClient then
        ABRRadioMusicClient.receiveState(packet)
    end
    local text = lineText
    if announcement and state.announcedSequence ~= state.sequence then
        local caption = M.caption(state.entry)
        if caption ~= "" then text = M.MUSIC_NOTE .. " " .. caption end
    end
    -- Control packets never pass through vanilla speech/static simulation.
    if text and text ~= "" then
        local radio = ABRRadio.getRadio()
        if radio then
            local color = station.color
            radio:SendTransmission(0, 0, station.frequency, text, "", "",
                color.r, color.g, color.b, station.signalStrength, false)
            if announcement then state.announcedSequence = state.sequence end
        end
    end
    state.sinceBroadcast = 0
end

local function broadcastTalkLine(station, state)
    if state.entry.kind ~= "talk" then return end
    local index = M.talkLineIndex(state.entry, state.elapsed)
    if index == 0 or index <= state.textIndex then return end
    state.textIndex = index
    local text = ABRRadio.resolveText(state.entry.lines[index].text)
    if text ~= "" then broadcast(station, state, false, text) end
end

local function start(station, state, entry)
    S.sequence = S.sequence + 1
    state.entry, state.sequence, state.elapsed = entry, S.sequence, 0
    state.phase = entry.kind == "song" and "announce" or "play"
    state.phaseElapsed, state.sinceBroadcast = 0, 0
    state.announcementDuration = state.afterTalk and M.AFTER_TALK_ANNOUNCEMENT_DURATION or M.ANNOUNCEMENT_DURATION
    state.afterTalk = false
    state.textIndex = 0
    if entry.kind == "song" then state.previousSong = entry.id end
    if entry.kind == "talk" then state.previousTalk = entry.id end
    broadcast(station, state, entry.kind == "song")
    broadcastTalkLine(station, state)
end

local function startNext(id, station, state)
    local entry
    if state.wantTalk then entry = M.pick(station.talks, state.previousTalk) end
    local queue = S.queues[id] or {}
    local requested = not entry and queue[1]
    if requested then entry = M.content[requested.songId] end
    entry = entry or M.pick(station.songs, state.previousSong)
    if entry and ABRRadioServer.tryAcquireChannel(id, "music") then
        if requested then table.remove(queue, 1) end
        state.wantTalk = false
        state.waitReason = nil
        start(station, state, entry)
    else
        state.waitReason = entry and "waiting_for_channel" or "waiting_for_songs"
    end
end

-- RCON catalogs may only know script sound names. Resolve those against the
-- station's registered songs, then keep catalog IDs in the playback queue.
local function resolveRequestedSong(station, reference)
    local song = M.content[reference]
    if song and song.kind == "song" and song.station == station.id then return song end
    for _, candidate in ipairs(station.songs) do
        if candidate.sound == reference then return candidate end
    end
    return nil, "Unknown song for station: " .. tostring(reference)
end

-- Validate the entire batch before changing the queue. IDs belong to the
-- selected station; explicit requests may intentionally repeat a song.
function S.queueSongs(stationId, songIds, playerName, message)
    local station = M.stations[stationId]
    if not station or not ABRRadio.isChannelEnabled(stationId) then return false, "Unknown or disabled station" end
    if type(songIds) ~= "table" or #songIds == 0 or #songIds > S.MAX_BATCH then return false, "Invalid batch size" end
    if type(playerName) ~= "string" or not playerName:find("%S") or #playerName > 64 then return false, "Invalid player name" end
    if type(message) ~= "string" or #message > 240 then return false, "Invalid message" end
    if playerName:find("[%c<>%[%]]") or message:find("[%c<>%[%]]") then return false, "Control characters or radio markup are not allowed" end
    local queue = S.queues[stationId] or {}
    if #queue + #songIds > S.MAX_QUEUE then return false, "Station queue is full" end
    if S.notices[stationId] and #S.notices[stationId] >= S.MAX_QUEUE * 2 then return false, "Station announcements are full" end
    local dedications = S.dedications[stationId] or {}
    if message:find("%S") and #dedications >= S.MAX_QUEUE then return false, "Station messages are full" end
    local resolvedIds = {}
    for _, songId in ipairs(songIds) do
        local song, reason = resolveRequestedSong(station, songId)
        if not song then return false, reason end
        resolvedIds[#resolvedIds + 1] = song.id
    end
    S.queues[stationId] = queue
    if message:find("%S") then
        S.dedications[stationId] = dedications
        local state = S.states[stationId]
        table.insert(dedications, { playerName = playerName, message = message,
            remaining = S.MESSAGE_REPEATS,
            skipSequence = state and state.entry and state.entry.kind == "song" and state.sequence or nil })
    end
    for _, songId in ipairs(resolvedIds) do
        table.insert(queue, { songId = songId, playerName = playerName, message = message })
    end
    local function text(key, args)
        return ABRRadio.resolveRegisteredLabel("RD_ABR_Jukebox_" .. key, args)
    end
    local caption = M.caption(M.content[queue[1].songId])
    if caption == "" then caption = queue[1].songId end
    local first = #songIds == 1 and text("Queued", { playerName, caption })
        or text("BatchQueued", { playerName, #songIds, caption })
    if message ~= "" then first = first .. " " .. text("Message", { playerName, message }) end
    local notices = S.notices[stationId] or {}
    S.notices[stationId] = notices
    table.insert(notices, first)
    table.insert(notices, text("Remaining", { #queue - 1 }))
    -- Wake the bounded station scan; do not interrupt or restart current audio.
    S.waitTicks = 0
    return true, #queue
end

-- Announcer copy is independent of song requests and player dedications.
-- Append each command atomically; drain all lines before the next song.
-- Strings use the default pause; tables supply { text, intervalAdjustment }.
function S.queueAnnouncerMessages(stationId, messages)
    if not M.stations[stationId] or not ABRRadio.isChannelEnabled(stationId) then
        return false, "Unknown or disabled station"
    end
    if type(messages) ~= "table" or #messages == 0 or #messages > S.MAX_BATCH then
        return false, "Invalid batch size"
    end
    local queue = S.announcerQueues[stationId] or {}
    if #queue + #messages > S.MAX_QUEUE then return false, "Station announcer queue is full" end
    local validated = {}
    for _, message in ipairs(messages) do
        local text = type(message) == "table" and message.text or message
        local adjustment = type(message) == "table" and message.intervalAdjustment or 0
        if type(text) ~= "string" or not text:find("%S") or #text > 480
            or text:find("[%c<>%[%]]") then return false, "Invalid announcer message" end
        if type(adjustment) ~= "number" or adjustment ~= adjustment
            or adjustment == math.huge or adjustment == -math.huge then
            return false, "Invalid announcer interval adjustment"
        end
        validated[#validated + 1] = { text = text,
            interval = math.max(S.MIN_ANNOUNCER_INTERVAL, S.ANNOUNCER_INTERVAL + adjustment) }
    end
    S.announcerQueues[stationId] = queue
    for _, message in ipairs(validated) do table.insert(queue, message) end
    return true, #queue
end

local function prepareDedications(id, state)
    state.dedicationLines = {}
    for _, dedication in ipairs(S.dedications[id] or {}) do
        if dedication.remaining > 0 and dedication.skipSequence ~= state.sequence then
            table.insert(state.dedicationLines, dedication)
        end
    end
    -- Hold the outgoing song's end state while these messages air, before
    -- ordinary announcer content or the next song acquires the channel.
    if #state.dedicationLines > 0 then
        state.intermission = math.max(state.intermission, (#state.dedicationLines + 1) * 3)
    end
    local announcers = S.announcerQueues[id] or {}
    state.announcerActive = #announcers > 0
    state.announcerNextAt = nil
    if state.announcerActive then
        state.intermission = (#state.dedicationLines + 1) * 3
    end
end

local function broadcastDedication(id, station, state, now)
    local lines = state.dedicationLines
    if not lines or #lines == 0 or state.phaseElapsed < 3 then return end
    if state.noticeAt and now - state.noticeAt < 3000 then return end
    local radio = ABRRadio.getRadio()
    if not radio then return end
    local dedication = lines[1]
    local text = ABRRadio.resolveRegisteredLabel("RD_ABR_Jukebox_Dedication",
        { dedication.playerName, dedication.message })
    local color = station.color
    radio:SendTransmission(0, 0, station.frequency, text, "", "",
        color.r, color.g, color.b, station.signalStrength, false)
    table.remove(lines, 1)
    dedication.remaining = dedication.remaining - 1
    state.noticeAt = now
    -- Leave a reading pause after the last message even after a server stall.
    state.intermission = math.max(state.intermission, state.phaseElapsed + 3)
    local active = S.dedications[id] or {}
    for i = #active, 1, -1 do
        if active[i].remaining == 0 then table.remove(active, i) end
    end
end

local function broadcastAnnouncer(id, station, state, now)
    local queue = S.announcerQueues[id] or {}
    if #queue == 0 then return end
    if not state.announcerActive then state.intermission = state.phaseElapsed end
    state.announcerActive = true
    if state.phaseElapsed < 3
        or (state.dedicationLines and #state.dedicationLines > 0) then return end
    if state.announcerNextAt then
        if now < state.announcerNextAt then return end
    elseif state.noticeAt and now - state.noticeAt < 3000 then return end
    local radio = ABRRadio.getRadio()
    if not radio then return end
    local color = station.color
    local message = queue[1]
    radio:SendTransmission(0, 0, station.frequency, message.text, "", "",
        color.r, color.g, color.b, station.signalStrength, false)
    table.remove(queue, 1)
    state.wantTalk = false
    state.afterTalk = true
    state.noticeAt = now
    state.announcerNextAt = now + message.interval * 1000
    -- Leave a reading pause without registering dynamic shared catalog entries.
    state.intermission = math.max(state.intermission, state.phaseElapsed + message.interval)
end

local function broadcastNotice(id, station, state, now)
    local notices = S.notices[id]
    if not notices or #notices == 0 then return end
    -- Request notices must not interrupt a conversation or its final pause.
    if state.phase == "end" and state.announcerActive then return end
    -- Respect text ownership; ordinary music heartbeats remain independent.
    if ABRRadioServer.channelOwners[id] ~= "music" then return end
    if state.noticeAt and now - state.noticeAt < 3000 then return end
    local radio = ABRRadio.getRadio()
    if not radio then return end
    local color = station.color
    radio:SendTransmission(0, 0, station.frequency, table.remove(notices, 1), "", "",
        color.r, color.g, color.b, station.signalStrength, false)
    state.noticeAt = now
end

local function updateStation(id, station, now)
    local state = S.states[id]
    if not state then state = {}; S.states[id] = state end
    -- Include all real time since this station's previous visit, including
    -- the scan delay and server stalls. Frame delta would lose that time.
    local delta = state.checkedAt and math.max(0, (now - state.checkedAt) / 1000) or 0
    state.checkedAt = now
    if ABRRadio.isChannelEnabled(id) then
        state.waitReason = nil
        if not state.entry then
            -- With an empty template catalog, stay silent until songs exist.
            startNext(id, station, state)
        else
            state.phaseElapsed = state.phaseElapsed + delta
            state.sinceBroadcast = state.sinceBroadcast + delta
            if state.phase == "announce" then
                if state.phaseElapsed >= state.announcementDuration then
                    state.phase, state.phaseElapsed = "play", 0
                    broadcast(station, state)
                elseif state.sinceBroadcast >= M.HEARTBEAT then
                    broadcast(station, state)
                end
            elseif state.phase == "end" then
                broadcastDedication(id, station, state, now)
                broadcastAnnouncer(id, station, state, now)
                -- Keep ownership through the pause so text cannot start early.
                if state.phaseElapsed >= state.intermission
                    and #(S.announcerQueues[id] or {}) == 0
                    and (not state.announcerNextAt or now >= state.announcerNextAt)
                    and (not state.dedicationLines or #state.dedicationLines == 0) then
                    state.entry = nil
                    ABRRadioServer.releaseChannel(id, "music")
                    startNext(id, station, state)
                elseif state.sinceBroadcast >= M.HEARTBEAT then
                    broadcast(station, state)
                end
            else
                state.elapsed = state.elapsed + delta
                local ending = state.entry.duration
                if state.entry.kind == "talk" and #state.entry.lines > 0 then
                    ending = math.min(ending, state.entry.lines[#state.entry.lines].at + M.TALK_LAST_LINE_HOLD)
                end
                if state.elapsed >= ending then
                    print("[ABRRadio Music Server] Completed: " .. stationLabel(station)
                        .. "; " .. state.entry.kind .. "=" .. state.entry.id)
                    state.elapsed = state.entry.duration
                    state.phase, state.phaseElapsed = "end", 0
                    broadcast(station, state)
                    state.wantTalk = state.entry.kind == "song" and #station.talks > 0
                    if state.entry.kind == "song" then
                        state.intermission = state.wantTalk and 0 or ZombRand(M.INTERMISSION_MIN, M.INTERMISSION_MAX + 1)
                        prepareDedications(id, state)
                        if state.intermission == 0 then
                            state.entry = nil
                            ABRRadioServer.releaseChannel(id, "music")
                            startNext(id, station, state)
                        end
                    else
                        state.afterTalk = true
                        state.entry = nil
                        ABRRadioServer.releaseChannel(id, "music")
                        startNext(id, station, state)
                    end
                else
                    if state.entry.kind == "song" and state.phase == "play"
                        and state.elapsed >= ending - M.TRANSITION_LEAD_SECONDS then
                        state.phase = "transition"
                        broadcast(station, state)
                    end
                    broadcastTalkLine(station, state)
                    if state.sinceBroadcast >= M.HEARTBEAT then broadcast(station, state) end
                end
            end
        end
    else
        state.waitReason = "disabled"
        if state.entry then
            state.phase = "stop"
            state.elapsed = state.entry.duration
            broadcast(station, state)
        end
        state.entry = nil
        state.dedicationLines = nil
        state.announcerActive = nil
        state.announcerNextAt = nil
        state.wantTalk = false
        ABRRadioServer.releaseChannel(id, "music")
    end
    broadcastNotice(id, station, state, now)
    -- Keep the one-station-per-tick budget, but avoid the 50-tick sleep while
    -- announcing, ending a pause, or delivering short timed announcer lines.
    local fast = state.entry ~= nil and ((S.notices[id] and #S.notices[id] > 0)
        or state.entry.kind == "talk" or state.phase ~= "play"
        or state.entry.duration - state.elapsed <= M.HEARTBEAT + M.TRANSITION_LEAD_SECONDS)
    if fast ~= (state.fast == true) then
        S.fastStations = S.fastStations + (fast and 1 or -1)
        state.fast = fast
    end
    logRuntime(station, state, now)
end

local function tick()
    if not S.ready then return end
    if #M.stationIds == 0 then
        local now = getTimestampMs()
        if not S.emptyLoggedAt or now - S.emptyLoggedAt >= S.LOG_INTERVAL_MS then
            print("[ABRRadio Music Server] Runtime: waiting for registered music stations.")
            S.emptyLoggedAt = now
        end
        return
    end
    if S.waitTicks > 0 then
        S.waitTicks = S.waitTicks - 1
        return
    end

    local id = M.stationIds[S.scanIndex]
    if id then
        local station = M.stations[id]
        if station then updateStation(id, station, getTimestampMs()) end
        S.scanIndex = S.scanIndex + 1
    end
    if S.scanIndex > #M.stationIds or not id then
        S.scanIndex = 1
        S.waitTicks = S.fastStations > 0 and 0 or M.SCAN_WAIT_TICKS
    end
end

Events.OnLoadRadioScripts.Add(function()
    S.ready = true
    print("[ABRRadio Music Server] Controller ready: " .. #M.stationIds
        .. " stations; runtime heartbeat every 60 seconds.")
    for _, id in ipairs(M.stationIds) do
        local station = M.stations[id]
        print("[ABRRadio Music Server] Station ready: " .. stationLabel(station)
            .. "; songs=" .. #station.songs .. "; talks=" .. #station.talks
            .. "; enabled=" .. tostring(ABRRadio.isChannelEnabled(id)))
    end
end)
Events.OnTick.Add(tick)
print("[ABRRadio Music Server] Controller loaded; waiting for OnLoadRadioScripts.")
