require "ApocalipseBRRadio/ABRRadioFramework"

-- Shared by the authority and listeners. IDs are short, stable catalog codes,
-- never array indices: adding a pack must not change another pack's wire IDs.
ABRRadio.music = ABRRadio.music or { stations = {}, content = {} }
local M = ABRRadio.music
M.stationIds = M.stationIds or {}
-- Compatibility for previously generated catalog modules; new packs use ABRRadio.
ApocalipseMusic = M
M.PREFIX = "AMP2|"
M.SCAN_WAIT_TICKS = 50
M.TARGET_TICKS_PER_SECOND = 10
M.HEARTBEAT = 5
-- Freshness of discovery snapshots only; active audio has no heartbeat deadline.
M.TIMEOUT = 8
M.MUSIC_NOTE = "[img=music]"
M.ANNOUNCEMENT_DURATION = 3
M.FADE_DURATION = 2
M.FADE_OUT_FRAMES = 100
M.FADE_IN_FRAMES = 50
M.TRANSITION_LEAD_SECONDS = 100 / 60
M.AFTER_TALK_ANNOUNCEMENT_DURATION = 0.5
M.TALK_LAST_LINE_HOLD = 2
M.PLAY_RETRY = 2
M.INTERMISSION_MIN = 0
M.INTERMISSION_MAX = 5
M.LISTEN_RANGE = 200 * 0.9144 -- playback activation/lifetime radius
M.PROPAGATION_RANGE = 100 * 0.9144 -- maximum audible radius at full radio volume
M.FULL_VOLUME_RANGE = 10
M.DISTANCE_FALLOFF_POWER = 2
M.FASTER_FALLOFF_THRESHOLD = 60 * 0.9144
M.LONG_RANGE_FALLOFF_RATE = 1.2
M.GLOBAL_FALLOFF_RATE = 1.3
M.SPEAKER_REFERENCE_RANGE = 15
M.PORTABLE_SPEAKER_SCALE = 0.6
M.VEHICLE_SPEAKER_SCALE = 1
M.STATIONARY_SPEAKER_SCALE = 1
-- Vanilla vehicle siren AI sound values (independent of audible music range).
M.ZOMBIE_SOUND_RADIUS = 100
M.ZOMBIE_SOUND_VOLUME = 60

-- Allow three complete scans before rejecting a cached discovery snapshot.
-- Scan length grows with station count: the authority visits one per tick.
function M.getHeartbeatTimeout()
    local scanSeconds = (M.SCAN_WAIT_TICKS + #M.stationIds) / M.TARGET_TICKS_PER_SECOND
    return math.max(M.TIMEOUT, scanSeconds * 3)
end

local function validId(id)
    return type(id) == "string" and #id > 0 and #id <= 24
        and id:match("^[%w_%-]+$") ~= nil
end

function M.registerStation(config)
    assert(validId(config.id), "Invalid music station ID")
    assert(not M.stations[config.id], "Duplicate music station ID")
    assert(type(config.frequency) == "number" and config.frequency > 0
        and config.frequency == math.floor(config.frequency), "Station needs an integer frequency")
    assert(config.isTV ~= true, "Music stations must be radio channels")
    assert(config.attractZombies == nil or type(config.attractZombies) == "boolean",
        "attractZombies must be a boolean")
    assert(not ABRRadio.getChannelIdByFrequency(config.frequency), "Radio frequency already registered")
    config.color = config.color or { r = 0.8, g = 0.65, b = 0.25 }
    config.signalStrength = config.signalStrength or -1
    config.talkChance = config.talkChance or 35
    assert(config.talkChance >= 0 and config.talkChance <= 100, "Talk probability must be 0-100")
    assert(ABRRadio.registerChannel(config), "Radio registration failed")
    config.songs, config.talks = {}, {}
    M.stations[config.id] = config
    table.insert(M.stationIds, config.id)
end

local function register(config, kind)
    assert(validId(config.id), "Invalid content ID")
    assert(not M.content[config.id], "Duplicate content ID: " .. config.id)
    local station = assert(M.stations[config.station], "Unknown music station")
    assert(type(config.duration) == "number" and config.duration > 0, "Duration must be real seconds")
    config.weight = config.weight or 10
    assert(config.weight > 0 and config.weight == math.floor(config.weight), "Weight must be a positive integer")
    local previous = -1
    for _, line in ipairs(kind == "talk" and (config.lines or {}) or {}) do
        assert(type(line.at) == "number" and line.at >= 0 and line.at < config.duration
            and line.at > previous, "Text timestamps must increase and fall within duration")
        assert(line.text, "Timed text requires text")
        if line.untilTime then
            assert(line.untilTime > line.at and line.untilTime <= config.duration, "Invalid text end time")
        end
        previous = line.at
    end
    if kind == "song" then
        -- Discard obsolete song text fields from existing content packs.
        config.lyrics, config.lyricDuration, config.lines = nil, nil, nil
        if config.chunks and #config.chunks == 0 then config.chunks = nil end
        assert(type(config.sound) == "string" or #(config.chunks or {}) > 0, "Song needs sound or chunks")
        previous = -1
        for i, chunk in ipairs(config.chunks or {}) do
            assert(type(chunk.at) == "number" and chunk.at >= 0 and chunk.at < config.duration
                and chunk.at > previous and type(chunk.sound) == "string", "Invalid audio chunk")
            assert(i ~= 1 or chunk.at == 0, "First audio chunk must start at zero")
            previous = chunk.at
        end
    end
    config.kind = kind
    M.content[config.id] = config
    table.insert(kind == "song" and station.songs or station.talks, config)
end

function M.registerSong(config) register(config, "song") end
function M.registerTalk(config) register(config, "talk") end

function M.pick(pool, previousId, excludedIds)
    local total = 0
    for _, entry in ipairs(pool) do
        if (not excludedIds or not excludedIds[entry.id])
            and (#pool == 1 or entry.id ~= previousId) then total = total + entry.weight end
    end
    if total == 0 then return nil end
    local roll = ZombRand(total)
    for _, entry in ipairs(pool) do
        if (not excludedIds or not excludedIds[entry.id])
            and (#pool == 1 or entry.id ~= previousId) then
            roll = roll - entry.weight
            if roll < 0 then return entry end
        end
    end
end

-- Receivers only need the active content, cycle, and lifecycle phase.
function M.encode(id, sequence, phase)
    return M.PREFIX .. id .. "|" .. string.format("%.0f", sequence) .. "|" .. (phase or "play")
end

function M.decode(codes)
    if type(codes) ~= "string" or #codes > 100 then return nil end
    local id, sequence, phase = codes:match("^AMP2|([%w_%-]+)|(%d+)|(%a+)$")
    if phase ~= "announce" and phase ~= "play" and phase ~= "transition"
        and phase ~= "end" and phase ~= "stop" then return nil end
    if not id or not validId(id) then return nil end
    return id, tonumber(sequence), phase
end

function M.caption(entry)
    local title = ABRRadio.resolveText(entry.title)
    local artist = ABRRadio.resolveText(entry.artist)
    if title == "" then return artist end
    return title .. (artist ~= "" and (" - " .. artist) or "")
end

function M.talkLineIndex(entry, elapsed)
    local lines = entry.lines or {}
    for i = #lines, 1, -1 do
        local line = lines[i]
        if elapsed >= line.at then
            local nextAt = (lines[i + 1] and lines[i + 1].at) or entry.duration
            local ending = line.untilTime or nextAt
            ending = math.min(ending, nextAt, entry.duration)
            if elapsed < ending then return i end
            return 0
        end
    end
    return 0
end

function M.chunkIndex(entry, elapsed)
    local chunks = entry.chunks or {}
    for i = #chunks, 1, -1 do
        if elapsed >= chunks[i].at then return i end
    end
    return 0
end
