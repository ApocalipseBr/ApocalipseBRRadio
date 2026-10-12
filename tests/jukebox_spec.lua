-- Runs after music_spec.lua, using its native API/event simulation.
unpack = table.unpack -- Kahlua global, absent in Fengari's Lua 5.3.
local S, M = ABRRadioMusicServer, ABRRadio.music
ABRRadio.registerMusicStation({ id = "jukebox_test", name = "Jukebox", frequency = 94300 })
for _, id in ipairs({ "juke_a", "juke_b" }) do
    ABRRadio.registerSong({ id = id, station = "jukebox_test", sound = id, duration = 2, title = id })
end
local handler, announcerHandler
package.preload.ApocBRRCON = function()
    ApocBRRCON = { subscribe = function(module, command, callback)
        if module == "Jukebox" and command == "Queue" then handler = callback
        elseif module == "Radio" and command == "QueueAnnouncer" then announcerHandler = callback
        else error("Unexpected RCON subscriber") end
    end }
end
require "ApocalipseBRRadio/ABRRadioJukeboxRCON"
assert(handler, "RCON subscriber missing")
local function request(payload) return handler(payload, { requestId = "test" }) end
assert(request("jukebox_test##Alice##juke_b,juke_a##Hello ## everyone"))
assert(#S.queues.jukebox_test == 2 and #S.notices.jukebox_test == 2,
    "batch must enqueue two songs with only two announcement lines")
assert(S.queues.jukebox_test[1].message == "Hello ## everyone")
assert(S.queues.jukebox_test[1].playerName == "Alice")
assert(not request("jukebox_test##Bob##juke_a,missing##bad"))
assert(not request("jukebox_test##Bob##whole##wrong station"))
assert(not request("jukebox_test##Bob##juke_a,##bad list"))
assert(not request("jukebox_test##Bob##juke_a##<bzzt>"))
assert(not request("missing##Bob##juke_a##bad station"))
assert(not request("jukebox_test## ##juke_a##bad player"))
assert(#S.queues.jukebox_test == 2, "invalid request partially changed queue")
local oldMax = S.MAX_QUEUE
S.MAX_QUEUE = 2
assert(not request("jukebox_test##Bob##juke_a##full"))
S.MAX_QUEUE = oldMax
S.dedications.jukebox_test = {} -- Exercise repeat lifecycle separately below.
local originalAcquire, originalClock, originalRadio = ABRRadioServer.tryAcquireChannel, getTimestampMs, ABRRadio.getRadio
local canAcquire, now, lines = false, 0, {}
ABRRadioServer.tryAcquireChannel = function(id, owner)
    if canAcquire then ABRRadioServer.channelOwners[id] = owner end
    return canAcquire
end
function getTimestampMs() return now end
ABRRadio.getRadio = function() return { SendTransmission = function(_, x, y, frequency, text)
    lines[#lines + 1] = text
end } end
S.ready, S.scanIndex, S.waitTicks, S.fastStations = true, 1, 0, 0
M.stationIds = { "jukebox_test" }
local function step(seconds)
    now = now + seconds * 1000
    S.waitTicks = 0
    Events.OnTick.fire()
end
step(0)
assert(#S.queues.jukebox_test == 2 and #lines == 0, "busy channel consumed request or broadcast notice")
canAcquire = true
step(0)
assert(S.states.jukebox_test.entry.id == "juke_b" and #S.queues.jukebox_test == 1)
assert(#S.notices.jukebox_test == 1, "first notice not broadcast")
step(1)
assert(#S.notices.jukebox_test == 1, "queue count broadcast too early")
step(2)
assert(#S.notices.jukebox_test == 0, "second notice missing")
assert(request("jukebox_test##Bob##juke_b##Another request"))
S.dedications.jukebox_test = {}
assert(S.states.jukebox_test.entry.id == "juke_b" and S.states.jukebox_test.phase == "play",
    "enqueue interrupted current song")
step(2)
step(5)
assert(S.states.jukebox_test.entry.id == "juke_a" and #S.queues.jukebox_test == 1,
    "queue did not preserve FIFO")
step(3); step(2); step(5)
assert(S.states.jukebox_test.entry.id == "juke_b" and #S.queues.jukebox_test == 0)
step(3); step(2); step(5)
assert(S.states.jukebox_test.entry ~= nil, "random playback did not resume after queue drained")

-- Empty messages create no repeat entry; each non-empty command creates one
-- entry, independent of the number of requested songs.
local originalText = getText
function getText(key, ...)
    if key == "RD_ABR_Jukebox_Dedication_EN" then
        local args = { ... }
        return "dedication:" .. args[1] .. ":" .. args[2]
    end
    return originalText(key, ...)
end
assert(request("jukebox_test##Silent##juke_a##"))
assert(#S.dedications.jukebox_test == 0, "empty message created repeat entry")
assert(request("jukebox_test##Alice##juke_a,juke_b##Stay alive"))
assert(request("jukebox_test##Bob##juke_b##Keep dancing"))
assert(#S.dedications.jukebox_test == 2, "batch stored message more than once")
ABRRadio.registerMusicTalk({ id = "juke_talk", station = "jukebox_test", duration = 5,
    lines = { { at = 0, text = "Normal announcer" } } })
local acceptedSequence = S.states.jukebox_test.sequence
local completions, talks = 0, 0
local seenSongs, seenTalks = {}, {}
for _ = 1, 250 do
    local previous = S.states.jukebox_test
    local previousSong = previous.entry and previous.entry.kind == "song" and previous.sequence
    step(1)
    local state = S.states.jukebox_test
    local completed = state.entry and state.entry.kind == "song" and state.phase == "end" and state.sequence
        or previousSong and previousSong ~= state.sequence and previousSong
    if completed and not seenSongs[completed] then
        seenSongs[completed] = true
        if completed ~= acceptedSequence then completions = completions + 1 end
    end
    if state.entry and state.entry.kind == "talk" and not seenTalks[state.sequence] then
        seenTalks[state.sequence] = true
        talks = talks + 1
    end
    local alice, bob = 0, 0
    for _, line in ipairs(lines) do
        if line == "dedication:Alice:Stay alive" then alice = alice + 1 end
        if line == "dedication:Bob:Keep dancing" then bob = bob + 1 end
    end
    assert(alice <= math.min(5, completions) and bob <= math.min(5, completions),
        "message repeated during current song, talk, or more than once per gap")
    if completions >= 7 then
        assert(alice == 5 and bob == 5 and #S.dedications.jukebox_test == 0,
            "messages did not expire after exactly five additional broadcasts")
        assert(talks >= 5, "dedication broke ordinary announcer scheduling")
        break
    end
end
assert(completions >= 7, "repeat simulation did not finish")

-- AI-fed announcer messages replace catalog talk, without replacing player
-- messages, replaying a message, or touching the song request queue.
ABRRadio.registerMusicStation({ id = "announcer_test", name = "Announcer", frequency = 94400 })
ABRRadio.registerSong({ id = "announcer_song", station = "announcer_test", sound = "song", duration = 2 })
ABRRadio.registerMusicTalk({ id = "announcer_talk", station = "announcer_test", duration = 5,
    lines = { { at = 0, text = "Default radio voice" } } })
assert(announcerHandler, "Announcer subscriber missing")
local function feed(payload) return announcerHandler(payload, { requestId = "announcer-test" }) end
assert(feed("announcer_test##First AI message, with a comma##Second AI message"))
assert(not feed("announcer_test##Valid##"))
assert(not feed("announcer_test##<bzzt>"))
assert(not feed("announcer_test##" .. string.rep("x", 481)))
assert(not feed("missing##Invalid station"))
assert(#S.announcerQueues.announcer_test == 2, "invalid batch changed announcer queue")
local savedMax = S.MAX_QUEUE
S.MAX_QUEUE = 2
assert(not feed("announcer_test##Overflow"))
S.MAX_QUEUE = savedMax
assert(feed("jukebox_test##Other station AI"))
assert(request("announcer_test##Listener##announcer_song##Player dedication"))
assert(#S.dedications.announcer_test == 1 and #S.queues.announcer_test == 1,
    "announcer messages changed player/song queues")
M.stationIds, S.scanIndex, S.fastStations = { "announcer_test" }, 1, 0
canAcquire = false
local firstLine = #lines + 1
step(1)
assert(#S.announcerQueues.announcer_test == 2, "busy channel consumed announcer message")
canAcquire = true
step(1); step(3); step(2)
assert(S.states.announcer_test.phase == "end")
local transmittingRadio = ABRRadio.getRadio
ABRRadio.getRadio = function() return nil end
step(10)
assert(#S.announcerQueues.announcer_test == 2 and S.states.announcer_test.phase == "end",
    "unavailable radio consumed announcer or released pending message")
ABRRadio.getRadio = transmittingRadio
local aiLines, defaults, playerLines = 0, 0, 0
for _ = 1, 150 do
    step(1)
    aiLines, defaults, playerLines = 0, 0, 0
    for i = firstLine, #lines do
        local line = lines[i]
        if line == "dedication:Listener:Player dedication" then playerLines = playerLines + 1 end
        if line == "First AI message, with a comma" then
            assert(playerLines >= 1 and aiLines == 0, "first AI message displaced player message or repeated")
            aiLines = aiLines + 1
        elseif line == "Second AI message" then
            assert(playerLines >= 2 and aiLines == 1, "AI FIFO or player repeats broken")
            aiLines = aiLines + 1
        elseif line == "Default radio voice" then
            assert(aiLines == 2, "default talk ran while AI messages were pending")
            defaults = defaults + 1
        end
    end
    if defaults >= 1 then break end
end
assert(aiLines == 2 and defaults >= 1 and playerLines >= 3, "announcer replacement or fallback did not finish")
assert(#S.announcerQueues.announcer_test == 0 and #S.announcerQueues.jukebox_test == 1,
    "announcer queues not independent by station")
ABRRadio.registerMusicStation({ id = "voice_only", name = "No catalog talk", frequency = 94500 })
ABRRadio.registerSong({ id = "voice_song", station = "voice_only", sound = "song", duration = 2 })
assert(feed("voice_only##A voice without catalog talk"))
M.stationIds, S.scanIndex, S.fastStations = { "voice_only" }, 1, 0
local voiceStart = #lines + 1
for _ = 1, 25 do step(1) end
local voiceCount = 0
for i = voiceStart, #lines do
    if lines[i] == "A voice without catalog talk" then voiceCount = voiceCount + 1 end
end
assert(voiceCount == 1 and #S.announcerQueues.voice_only == 0,
    "station without catalog talk did not broadcast announcer exactly once")
-- The backend reads script sound names, while playback uses catalog IDs.
ABRRadio.registerMusicStation({ id = "sound_lookup", name = "Sound lookup", frequency = 94600 })
ABRRadio.registerSong({ id = "amp_song_634c866c151b", station = "sound_lookup",
    sound = "AMP_634C866C151BF661", duration = 281 })
assert(request("sound_lookup##Alice##AMP_634C866C151BF661,amp_song_634c866c151b##Enjoy"))
assert(#S.queues.sound_lookup == 2 and S.queues.sound_lookup[1].songId == "amp_song_634c866c151b"
    and S.queues.sound_lookup[2].songId == "amp_song_634c866c151b", "sound references were not canonicalized")
assert(not request("jukebox_test##Alice##AMP_634C866C151BF661##Wrong station"))
assert(not request("sound_lookup##Alice##AMP_634C866C151BF661,amp_634c866c151bf661##Invalid batch"))
assert(#S.queues.sound_lookup == 2 and #S.notices.sound_lookup == 2
    and #S.dedications.sound_lookup == 1, "failed sound lookup partially changed state")
ABRRadio.registerSong({ id = "ambiguous_sound", station = "sound_lookup",
    sound = "AMP_634C866C151BF661", duration = 281 })
assert(request("sound_lookup##Alice##AMP_634C866C151BF661##First match"))
assert(#S.queues.sound_lookup == 3 and S.queues.sound_lookup[3].songId == "amp_song_634c866c151b",
    "sound lookup did not select the first registered match")
assert(request("sound_lookup##Alice##amp_song_634c866c151b##"), "catalog ID no longer resolves directly")
getText = originalText
ABRRadioServer.tryAcquireChannel, getTimestampMs, ABRRadio.getRadio = originalAcquire, originalClock, originalRadio
print("PASS: jukebox queues/repeats and independent AI announcer FIFO, validation, ownership, player priority and fallback")
