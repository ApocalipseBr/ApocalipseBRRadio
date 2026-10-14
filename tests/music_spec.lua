-- Behavioral simulation of the framework. Native Kahlua/FMOD still needs a
-- game smoke test; these checks exercise receiver and authority state changes.
local root = "Contents/mods/ApocalipseBRRadio/common/media/lua/"
-- Match PZ's Kahlua globals so native-Lua-only calls fail in this simulation.
next = nil
package.path = root .. "shared/?.lua;" .. root .. "client/?.lua;" .. root .. "server/?.lua;" .. package.path
local function event()
    local handlers = {}
    return { Add = function(fn) handlers[#handlers + 1] = fn end,
        fire = function(...) for _, fn in ipairs(handlers) do fn(...) end end }
end
Events = { OnTick = event(), OnLoadRadioScripts = event(), OnDeviceText = event(),
    EveryOneMinute = event(), OnClientCommand = event(), OnServerCommand = event() }
function isClient() return false end
function isServer() return false end
function getText(key) return key end
local clockMs = 1790000000000
function getTimestampMs() return clockMs end
local delta, randomHigh = 0.1, false
function ZombRand(min, max) return max and (randomHigh and max - 1 or min) or 0 end
function getGameTime() return { getRealworldSecondsSinceLastUpdate = function() return delta end } end
function sendClientCommand() error("music sent a listener report") end
CharacterTrait = { DEAF = "deaf" }
local on, frequency, volume, distance = true, 94200, 1, 0
local baseSpeakerRange, portableSpeaker, twoWaySpeaker = 15, false, false
local deaf, media, blocked, placed, installed = false, false, false, true, true
local equipped, headphoneType = nil, -1
local listReads, squareReads = {}, 0
local function list(items)
    return { size = function() return #items end, get = function(_, i)
        listReads[items] = (listReads[items] or 0) + 1
        return items[i + 1]
    end }
end
local inventoryItems, broadcastDevices, grid = {}, {}, {}
function instanceof(item, kind) return kind == "Radio" and item.radioItem == true end
function getCell()
    return { getGridSquare = function(_, x, y, z)
        squareReads = squareReads + 1
        return grid[x .. ":" .. y .. ":" .. z]
    end }
end
local player = { getX = function() return 0 end, getY = function() return 0 end,
    getZ = function() return 0 end, isDead = function() return false end,
    hasTrait = function() return deaf end, getEquipedRadio = function() return equipped end,
    getInventory = function() return { getItems = function() return list(inventoryItems) end } end }
function getNumActivePlayers() return 1 end
function getSpecificPlayer() return player end
local micMuted = false
local data = { getIsTurnedOn = function() return on end, getChannel = function() return frequency end,
    getBaseVolumeRange = function() return baseSpeakerRange end,
    getIsPortable = function() return portableSpeaker end,
    getIsTwoWay = function() return twoWaySpeaker end,
    getMicIsMuted = function() return micMuted end, setMicIsMuted = function(_, value) micMuted = value end,
    getDeviceVolume = function() return volume end, getDeviceSoundVolumeRange = function() return 20 end,
    getHeadphoneType = function() return headphoneType end, isPlayingMedia = function() return media end,
    isNoTransmit = function() return blocked end }
local captions, attempts, emitters, returned = {}, {}, {}, 0
local device = { getDeviceData = function() return data end,
    getSquare = function() return placed and {} or nil end,
    getObjectIndex = function() return placed and 0 or -1 end,
    getX = function() return distance end, getY = function() return 0 end,
    getZ = function() return 0 end,
    AddDeviceText = function(self, text) captions[#captions + 1] = text end }
local failNext = false
local world = {}
function world:getFreeEmitter(x, y, z)
    local emitter = { position = { x, y, z } }
    function emitter:playSound() error("replicated music playback") end
    function emitter:playSoundImpl(sound, worldSound, parent)
        assert(worldSound == false and parent == nil, "wrong local playback overload")
        attempts[#attempts + 1] = sound
        if failNext then failNext = false; return 0 end
        self.handle = #attempts
        self.stopped, self.finished = false, false
        return self.handle
    end
    function emitter:stopSoundLocal(handle) assert(handle > 0); self.stopped = true end
    function emitter:stopAll() self.stopped = true end
    function emitter:isPlaying(handle) return handle == self.handle and not self.stopped and not self.finished end
    function emitter:set3D(handle, value) assert(handle > 0); self.spatial = value end
    function emitter:setVolume(handle, value) assert(handle > 0); self.gain = value end
    function emitter:setPos(px, py, pz) self.position = { px, py, pz } end
    function emitter:tick() end
    emitters[#emitters + 1] = emitter
    return emitter
end
function world:takeOwnershipOfEmitter() end
function world:returnOwnershipOfEmitter(emitter) returned = returned + 1; emitter.returned = true end
function getWorld() return world end
local packets, radio = {}, {}
function getZomboidRadio() return radio end
function radio:addChannelName() end
function radio:getBroadcastDevices() return list(broadcastDevices) end
function radio:getDevices() return list(broadcastDevices) end
function radio:getDaysSinceStart() return 0 end
function radio:SendTransmission(x, y, freq, text, guid, codes)
    packets[#packets + 1] = { frequency = freq, text = text, codes = codes }
    if freq == frequency then Events.OnDeviceText.fire(guid, codes, x, y, 0, text, device) end
end
require "ApocalipseBRRadio/ABRRadioMusicClient"
require "ApocalipseBRRadio/ABRRadioMusicServer"
local M, C, S = ABRRadio.music, ABRRadioMusicClient, ABRRadioMusicServer
ABRRadio.registerMusicStation({ id = "music", name = "Radio", frequency = 94200, talkChance = 0 })
ABRRadio.registerSong({ id = "whole", station = "music", sound = "whole_file", duration = 20,
    title = "Track", artist = "Artist", lyrics = { { at = 1, text = "opening lyric" } } })
ABRRadio.registerSong({ id = "chunks", station = "music", duration = 20,
    chunks = { { at = 0, sound = "chunk_one" }, { at = 5, sound = "chunk_two" } } })
ABRRadio.registerSong({ id = "both", station = "music", duration = 20, sound = "whole_preferred",
    chunks = { { at = 0, sound = "unused_chunk" } } })
assert(M.content.whole.lyrics == nil and M.content.whole.lyricDuration == nil,
    "obsolete song lyrics retained in registry")
local function heartbeat(id, seq, phase)
    Events.OnDeviceText.fire("", M.encode(id, seq, phase), 0, 0, 0, M.MUSIC_NOTE, device)
end
local function advance(seconds)
    for _ = 1, math.floor(seconds / delta + 0.5) do
        clockMs = clockMs + delta * 1000
        Events.OnTick.fire()
    end
end
local function scan(count)
    for _ = 1, count or 1 do
        advance((S.waitTicks + #M.stationIds - S.scanIndex + 1) * delta)
        -- The listener's tick runs before the authority's tick in this harness.
        advance(delta)
    end
end
local function cleanup()
    on = false; advance(0.1); on = true
    assert(C.devices[device] == nil and C.fading[device] == nil, "receiver retained after power off")
end
local function active() return C.devices[device] end
local function distanceGain(at)
    local d = math.sqrt((at + 0.5)^2 + 0.5^2)
    local level = math.min(1, math.max(0, volume))
    local propagation = M.PROPAGATION_RANGE * level
    local inner = M.FULL_VOLUME_RANGE * level
    local rate = M.GLOBAL_FALLOFF_RATE
        * (propagation > M.FASTER_FALLOFF_THRESHOLD + 0.000001 and M.LONG_RANGE_FALLOFF_RATE or 1)
    return math.min(1, math.max(0, 1 - (d - inner) / (propagation - inner) * rate)) ^ M.DISTANCE_FALLOFF_POWER
end
for _, phase in ipairs({ "announce", "play", "end" }) do
    local codes = M.encode("whole", 1790000000000, phase)
    local id, seq, decoded = M.decode(codes)
    assert(codes == "AMP2|whole|1790000000000|" .. phase, "metadata includes timing fields")
    assert(id == "whole" and seq == 1790000000000 and decoded == phase)
end
assert(M.decode("AMP2|whole|1|bogus") == nil and M.decode("AMP2|whole|x|play") == nil
    and M.decode("AMP1|whole|1|0") == nil, "malformed or old protocol accepted")

heartbeat("whole", 10)
advance(0.1)
assert(attempts[#attempts] == "whole_file" and active().startedAt == C.clock, "late tune did not start at beginning")
local first = active().emitter
assert(first.gain == 0.5, "new song did not start at half radio volume")
heartbeat("whole", 10); heartbeat("whole", 10)
advance(4.9)
assert(math.abs(first.gain - 0.99) < 0.000001, "fade-in did not advance by client frames")
advance(0.1)
assert(first.gain == 1, "50-frame fade-in did not reach radio volume")
assert(#attempts == 1 and #captions == 0,
    "duplicate heartbeat restarted music or displayed removed lyrics")
baseSpeakerRange, portableSpeaker, twoWaySpeaker = 8, true, true
advance(delta)
assert(math.abs(first.gain - 0.32) < 0.000001,
    "budget walkie speaker did not reduce maximum loudness")
local hardwareHandle = active().handle
distance = 40 * 0.9144
advance(delta)
assert(first.gain == 0 and active().handle == hardwareHandle,
    "budget walkie's 32-yard propagation radius changed playback lifetime")
baseSpeakerRange, portableSpeaker, twoWaySpeaker = 30, false, false
distance = 0
advance(delta)
assert(first.gain == 1 and active().handle == hardwareHandle,
    "large modded speaker exceeded the maximum or restarted playback")
baseSpeakerRange = 15
local midway = (M.PROPAGATION_RANGE + M.FULL_VOLUME_RANGE) / 2
distance = math.sqrt(midway^2 - 0.5^2) - 0.5
advance(delta)
assert(math.abs(first.gain - 0.0484) < 0.000001,
    "long-range midpoint did not stack 1.3 and 1.2 attenuation rates")
local uninterruptedHandle, uninterruptedStart = active().handle, active().startedAt
volume = 0.5
advance(delta)
assert(first.gain == 0 and active().handle == uninterruptedHandle and active().startedAt == uninterruptedStart,
    "smaller propagation radius stopped playback instead of reducing gain")
distance = math.sqrt((midway * 0.5)^2 - 0.5^2) - 0.5
advance(delta)
assert(math.abs(first.gain - 0.06125) < 0.000001,
    "short-range midpoint did not apply the universal 1.3 attenuation rate")
volume = 1
advance(delta)
assert(first.gain > 0.125 and active().handle == uninterruptedHandle and #attempts == 1,
    "increasing propagation range restarted the airing")
volume, distance = 0.4, 10; advance(0.1)
assert(math.abs(first.gain - 0.4 * distanceGain(10)) < 0.000001 and not first.spatial and first.position[1] == 10.5, "receiver volume/position")
local musicRange = M.LISTEN_RANGE
distance = math.sqrt(musicRange^2 - 0.5^2) - 0.5 - 0.000001
advance(delta)
assert(active().emitter == first and math.abs(first.gain) < 0.000001 and not first.spatial,
    "200-yard boundary stopped/restarted music or retained audible gain")
distance = distance + 0.01
advance(delta)
assert(active() == nil and first.returned, "beyond 200 yards did not release playback")
heartbeat("whole", 10); advance(delta)
assert(active() == nil, "heartbeat activated a receiver beyond 200 yards")
distance = 10
heartbeat("whole", 10); advance(delta)
first = active().emitter
advance(5.1)
heartbeat("whole", 9)
assert(active().sequence == 10, "stale sequence accepted")
heartbeat("whole", 10, "transition")
advance(10) -- 100 client frames at the test's 10 FPS
assert(math.abs(first.gain - 0.2 * distanceGain(10)) < 0.000001 and not first.stopped, "100-frame transition did not reach 50% of radio volume")
heartbeat("whole", 10, "end")
advance(1)
assert(math.abs(first.gain - 0.2 * distanceGain(10)) < 0.000001 and not first.stopped, "end metadata silenced the outgoing song under announcer speech")
heartbeat("whole", 10)
assert(active().phase == "end", "stale play revived ended song")
heartbeat("whole", 10, "stop")
advance(2.1)
assert(first.stopped and first.returned and first.gain == 0, "explicit stop did not release the held tail")
cleanup(); volume, distance = 1, 0

heartbeat("chunks", 11); advance(0.1)
assert(attempts[#attempts] == "chunk_one", "legacy chunks joined at authority chunk")
advance(2); heartbeat("chunks", 11)
local chunkStarts = #attempts
active().emitter.finished = true; advance(delta)
assert(active().handle == nil and not active().ended and active().chunk == 1,
    "intermediate chunk completion ended the whole song")
advance(1.9); heartbeat("chunks", 11)
assert(#attempts == chunkStarts, "heartbeat replayed a naturally finished chunk")
advance(1.1)
assert(attempts[#attempts] == "chunk_two", "legacy chunks did not follow local clock")
active().emitter.finished = true; advance(delta)
chunkStarts = #attempts
heartbeat("chunks", 11); advance(delta)
assert(active().ended and active().handle == nil and #attempts == chunkStarts,
    "heartbeat replayed the completed final chunk")
cleanup()
heartbeat("both", 12); advance(0.1)
assert(attempts[#attempts] == "whole_preferred", "whole file did not take precedence")
cleanup()

failNext = true
local before, releases = #attempts, returned
heartbeat("whole", 13); advance(0.1)
assert(active().handle == nil and active().startedAt == nil and active().chunk == 0
    and returned == releases + 1, "zero handle accepted or failed emitter leaked")
advance(1)
assert(#attempts == before + 1, "failed playback retried every tick")
advance(1.1)
assert(active().handle and #attempts == before + 2, "failed playback did not recover")
local outgoing = active().emitter
heartbeat("both", 14)
advance(1)
assert(not outgoing.stopped and active().handle ~= nil, "replacement did not overlap outgoing fade")
advance(4.1)
assert(outgoing.returned and active().handle and attempts[#attempts] == "whole_preferred", "replacement did not start")
cleanup()

local seq = 20
for _, cause in ipairs({ "retune", "mute", "range", "pickup", "media", "blocked", "deaf" }) do
    seq = seq + 1; heartbeat("whole", seq); advance(0.1)
    local emitter = active().emitter
    if cause == "retune" then frequency = 95000 elseif cause == "mute" then volume = 0
    elseif cause == "range" then distance = 200 elseif cause == "pickup" then placed = false
    elseif cause == "media" then media = true elseif cause == "blocked" then blocked = true else deaf = true end
    advance(0.1)
    assert(active() == nil and emitter.returned, cause .. " did not release playback")
    frequency, volume, distance, placed, media, blocked, deaf = 94200, 1, 0, true, false, false, false
end
device.getPlayer = function() return player end
baseSpeakerRange, portableSpeaker = 8, true
equipped, headphoneType = device, 0
heartbeat("whole", 30); advance(0.1)
assert(active().emitter.spatial == false, "headphones were spatial")
assert(active().emitter.gain == 0.5, "headphones inherited the small speaker's loudness cap")
headphoneType = -1; advance(0.1)
assert(active().emitter.spatial == false, "speaker switch re-enabled directional panning")
equipped = nil; advance(0.1)
assert(active() == nil, "unequipping did not release playback")
device.getPlayer = nil
baseSpeakerRange, portableSpeaker = 10, false
local vehicle = { getX = function() return 3 end, getY = function() return 4 end,
    getZ = function() return 0 end, isRemovedFromWorld = function() return false end,
    getSquare = function() return {} end }
device.getVehicle = function() return vehicle end
device.getInventoryItem = function() return installed and {} or nil end
heartbeat("whole", 31); advance(0.1)
assert(active().emitter.position[1] == 3 and active().emitter.position[2] == 4, "vehicle placement")
assert(math.abs(active().emitter.gain - 1 / 3) < 0.000001,
    "vehicle speaker did not inherit its installed radio's native rating")
installed = false; advance(0.1)
assert(active() == nil, "uninstalling did not release playback")
device.getVehicle, device.getInventoryItem = nil, nil
baseSpeakerRange = 15
heartbeat("whole", 32); advance(delta)
local uninterrupted = active()
local heldEmitter, heldHandle, heldStart = uninterrupted.emitter, uninterrupted.handle, uninterrupted.startedAt
local previousStarts = #attempts
advance(M.getHeartbeatTimeout() * 3)
assert(active() == uninterrupted and active().handle == heldHandle and active().startedAt == heldStart
    and not active().ended and C.fading[device] == nil and not heldEmitter.stopped,
    "missing heartbeats interrupted ongoing local playback")
heartbeat("whole", 32); advance(delta)
assert(#attempts == previousStarts and active().handle == heldHandle,
    "returning heartbeat restarted ongoing audio")
heldEmitter.finished = true; advance(delta)
assert(active().ended and active().emitter == nil and heldEmitter.returned,
    "natural end did not release the local emitter")
heartbeat("whole", 32); advance(delta)
assert(active().ended and #attempts == previousStarts, "heartbeat replayed a naturally finished airing")
heartbeat("whole", 33); advance(delta)
assert(active().handle and #attempts == previousStarts + 1, "new airing did not start after natural completion")
heartbeat("whole", 33, "stop"); advance(M.FADE_DURATION + delta)
heartbeat("whole", 33, "play"); advance(delta)
assert(active().phase == "stop" and #attempts == previousStarts + 1,
    "heartbeat revived an explicitly stopped airing")
cleanup()
M.content.whole.duration = 0.1
heartbeat("whole", 33); advance(0.3)
assert(not active().ended and active().handle and C.fading[device] == nil,
    "client still tracks song duration")
heartbeat("whole", 33, "end")
local tail = C.fading[device].emitter
advance(M.getHeartbeatTimeout() * 3)
assert(C.fading[device] and not tail.stopped, "heartbeat silence stopped an unfinished outgoing tail")
tail.finished = true; advance(delta)
assert(tail.returned and C.fading[device] == nil, "naturally finished outgoing tail was not released")
cleanup()
assert(tail.returned, "power off did not kill a fading tail")
M.content.whole.duration = 20

-- Exercise the actual authority and text scheduler together.
local station = M.stations.music
station.songs = { M.content.whole }
Events.OnLoadRadioScripts.fire()
advance(5)
assert(S.states.music == nil and #packets == 0, "authority worked during the 50-tick wait")
advance(0.1)
assert(S.states.music.phase == "announce" and packets[#packets].text == "[img=music] Track - Artist"
    and active().handle == nil, "announcement missing or music started before it")
local function advanceUntil(predicate, seconds)
    local deadline = clockMs + (seconds or 40) * 1000
    while not predicate() and clockMs < deadline do advance(delta) end
    assert(predicate(), "controller transition timed out")
    advance(delta) -- listener updates after the authority's transition
end
local announcedSequence = S.states.music.sequence
advanceUntil(function() return S.states.music.phase == "play" end, 4)
assert(active().handle and S.states.music.sequence == announcedSequence)
local nativeAnnouncements = #packets
advance(5.2)
assert(#packets == nativeAnnouncements, "heartbeat repeated the server's native song announcement")
ABRRadio.registerChannel({ id = "other", name = "Other", frequency = 95000 })
ABRRadio.triggerImmediate("music", { "queued A", "queued B" })
ABRRadio.triggerImmediate("other", { "independent" })
local function countText(text)
    local count = 0
    for _, packet in ipairs(packets) do if packet.text == text then count = count + 1 end end
    return count
end
Events.EveryOneMinute.fire()
assert(countText("independent") == 1 and countText("queued A") == 0, "channel arbitration")
advanceUntil(function() return S.states.music.entry == nil end)
assert(S.states.music.intermission == 0 and ABRRadioServer.channelOwners.music == nil,
    "zero-second pause did not release queued text immediately")
Events.EveryOneMinute.fire(); advance(delta)
assert(countText("queued A") == 1 and S.states.music.entry == nil, "queued text did not get priority")
Events.EveryOneMinute.fire(); Events.EveryOneMinute.fire()
assert(countText("queued B") == 1, "queued text lost a line")
-- These timing checks intentionally replay the single-song fixture through
-- explicit requests; random rotation now exhausts after its first song.
S.queues.music = { { songId = "whole" }, { songId = "whole" },
    { songId = "whole" }, { songId = "whole" } }
randomHigh = true
advanceUntil(function() return S.states.music.phase == "play" and S.states.music.entry ~= nil end)
advanceUntil(function() return S.states.music.phase == "end" end)
assert(S.states.music.intermission == 5, "maximum pause is not inclusive")
local endedAt, packetCount = clockMs, #packets
advance(4)
assert(S.states.music.phase == "end" and ABRRadioServer.channelOwners.music == "music"
    and #packets == packetCount, "pause released ownership early or emitted vanilla heartbeat text")
advanceUntil(function() return S.states.music.phase == "announce" end, 2)
assert(clockMs - endedAt <= 5200, "pause gained another scan delay")
ABRRadio.channels.music.enabled = false
advanceUntil(function() return S.states.music.entry == nil end)
assert(ABRRadioServer.channelOwners.music == nil, "disabled station retained ownership")
cleanup()
ABRRadio.channels.music.enabled = true
randomHigh = false
station.talkChance = 0 -- announcer transitions are now mandatory when talks exist
ABRRadio.registerMusicTalk({ id = "talk", station = "music", duration = 12,
    lines = { { at = 0, text = "between songs" }, { at = 6, text = "second talk line" } } })
advanceUntil(function() return S.states.music.entry ~= nil and S.states.music.entry.id == "talk" end)
assert(countText("between songs") == 1, "announcer did not speak immediately after zero-second pause")
advance(6.1)
assert(countText("second talk line") == 1, "timed announcer line was skipped")
advanceUntil(function() return S.states.music.phase == "announce" end, 3)
advanceUntil(function() return S.states.music.phase == "play" end, 1)
assert(countText("queued A") == 1 and countText("queued B") == 1, "queued text repeated")
for _ in pairs(ABRRadioServer.listeners.music or {}) do error("music tracked listeners") end
for _, packet in ipairs(packets) do
    if packet.text == "between songs" or packet.text == "second talk line" then
        assert(packet.frequency == 94200 and packet.codes == "", "announcer bypassed normal radio text path")
    end
end
ABRRadio.registerMusicStation({ id = "music_two", name = "Second station", frequency = 96000, talkChance = 0 })
ABRRadio.registerSong({ id = "second_song", station = "music_two", duration = 1, sound = "second_file" })
advance(S.waitTicks * delta)
local firstChecked = S.states.music.checkedAt
advance(delta)
assert(S.states.music.checkedAt > firstChecked and S.states.music_two == nil,
    "more than one station was processed on a tick")
advance(delta)
assert(S.states.music_two.phase == "announce" and ABRRadioServer.channelOwners.music_two == "music")
randomHigh = true
advanceUntil(function() return S.states.music_two.phase == "end" end, 10)
assert(S.states.music_two.intermission == 5 and ABRRadioServer.channelOwners.music == "music")
local previousElapsed = S.states.music.elapsed
local previousChecked = S.states.music.checkedAt
clockMs = clockMs + 3000
scan()
assert(S.states.music.elapsed == previousElapsed + (S.states.music.checkedAt - previousChecked) / 1000,
    "station timing lost elapsed time during latency")

-- Add enough stations to exceed the old eight-second timeout and confirm the
-- per-tick processing budget and receiver survival through a complete scan.
for i = 1, 40 do
    ABRRadio.registerMusicStation({ id = "load_" .. i, name = "Load", frequency = 100000 + i })
end
local enabled = ABRRadio.isChannelEnabled
local visits = {}
ABRRadio.isChannelEnabled = function(id) visits[id] = true; return enabled(id) end
heartbeat("whole", S.sequence + 100, "play")
for _ = 1, M.SCAN_WAIT_TICKS + #M.stationIds do
    visits = {}
    advance(delta)
    local visited = 0
    for _ in pairs(visits) do visited = visited + 1 end
    assert(visited <= 1, "round-robin exceeded one station per tick")
end
assert(active() and active().phase == "play", "receiver expired during a large scan")
ABRRadio.isChannelEnabled = enabled
-- Protection must work without playback/heartbeats and preserve reception.
local function guardDevice(original)
    local d = { channel = 94200, muted = original, writes = 0 }
    function d:getIsTurnedOn() return false end
    function d:getChannel() return self.channel end
    function d:getMicIsMuted() return self.muted end
    function d:setMicIsMuted(value) self.muted = value; self.writes = self.writes + 1 end
    local receiver = { getDeviceData = function() return d end,
        getSquare = function() return {} end, getObjectIndex = function() return 0 end,
        getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end }
    return receiver, d
end
local receiver, guarded = guardDevice(false)
broadcastDevices[1] = receiver
volume, on = 0, false
advance(delta)
assert(guarded.muted and not blocked, "silent/off receiver was not protected without blocking reception")
local writes = guarded.writes
advance(delta)
assert(guarded.writes == writes, "unchanged microphone was written every tick")
guarded.muted = false
advance(delta)
assert(guarded.muted, "manual unmute was not corrected on the next tick")
guarded.channel = 95000
advance(delta)
assert(not guarded.muted and C.muted[receiver] == nil, "retuning did not restore the original microphone")
local alreadyMuted, originalMuted = guardDevice(true)
broadcastDevices[1] = alreadyMuted
advance(delta); originalMuted.channel = 95000; advance(delta)
assert(originalMuted.muted, "retuning overwrote an originally muted microphone")
local portable, portableData = guardDevice(false)
portable.radioItem = true
portable.getPlayer = function() return player end
inventoryItems[1] = portable
advance(delta)
assert(portableData.muted, "unequipped inventory radio was not protected")
portable.getPlayer = function() return nil end
advance(delta)
assert(not portableData.muted, "removed inventory radio retained the forced mute")
inventoryItems[1], broadcastDevices[1] = nil, nil
local vehiclePart, vehicleData = guardDevice(false)
vehiclePart.getVehicle = function() return { getSquare = function() return {} end,
    isRemovedFromWorld = function() return false end, getX = function() return 0 end,
    getY = function() return 0 end, getZ = function() return 0 end } end
vehiclePart.getInventoryItem = function() return {} end
grid["0:0:0"] = { getVehicleContainer = function() return {
    getPartById = function() return vehiclePart end } end, getWorldObjects = function() return list({}) end }
advance(4.2)
assert(vehicleData.muted, "nearby vehicle radio was not discovered")
vehicleData.channel = 95000; advance(delta)
assert(not vehicleData.muted, "vehicle retuning did not restore the microphone")
local dropped, droppedData = guardDevice(false)
dropped.radioItem = true
dropped.getPlayer = function() return nil end
dropped.getWorldItem = function() return receiver end
grid["0:0:0"] = { getVehicleContainer = function() return nil end,
    getWorldObjects = function() return list({ { getItem = function() return dropped end } }) end }
advance(4.2)
assert(droppedData.muted, "dropped nearby radio was not protected")
dropped.getWorldItem = function() return nil end
advance(delta)
assert(not droppedData.muted, "removed dropped radio retained forced mute")
grid["0:0:0"] = nil
for i = 1, 100 do
    local other, otherData = guardDevice(false)
    otherData.channel = 95000
    broadcastDevices[i], inventoryItems[i] = other, { radioItem = false }
end
local worldReads, itemReads, squares = listReads[broadcastDevices] or 0, listReads[inventoryItems] or 0, squareReads
advance(delta)
assert(listReads[broadcastDevices] - worldReads == 8 and listReads[inventoryItems] - itemReads == 8
    and squareReads - squares == 4, "discovery exceeded its per-tick scan budget")

-- Silent control packets discover a tuned receiver without OnDeviceText.
S.ready = false
C.devices, C.fading, C.muted, C.stations = {}, {}, {}, {}
broadcastDevices, inventoryItems = { device }, {}
-- A one-way receiver is registered in getDevices(), not getBroadcastDevices().
function radio:getBroadcastDevices() return list({}) end
on, volume, distance, placed, installed = true, 1, 0, true, true
frequency, media, blocked, deaf = 94200, false, false, false
distance = 150 * 0.9144
Events.OnServerCommand.fire(ABRRadio.NET_MODULE, "MusicState", {
    id = "whole", sequence = S.sequence + 1000, phase = "play",
})
advance(delta)
assert(active() and active().handle, "silent command did not start a discovered receiver")
assert(active().emitter.gain == 0 and not active().emitter.spatial,
    "150-yard receiver did not start silently before reaching audible range")
local warmHandle, warmStart, warmAttempts = active().handle, active().startedAt, #attempts
distance = 60 * 0.9144
advance(delta)
assert(active().emitter.gain > 0 and active().handle == warmHandle
    and active().startedAt == warmStart and #attempts == warmAttempts,
    "entering 100-yard propagation range restarted the prestarted track")
volume = 0.5
advance(delta)
assert(active().emitter.gain == 0 and active().handle == warmHandle,
    "half volume did not silence the receiver beyond 50 yards without stopping it")
volume = 1
advance(delta)
assert(active().emitter.gain > 0 and active().handle == warmHandle,
    "raising volume did not restore the same prestarted playback")
local playingHandle, playingSince, startsBefore = active().handle, active().startedAt, #attempts
for _ = 1, 5 do
    Events.OnServerCommand.fire(ABRRadio.NET_MODULE, "MusicState", {
        id = "whole", sequence = S.sequence + 1000, phase = "play",
    })
    advance(delta)
end
assert(active().handle == playingHandle and active().startedAt == playingSince
    and #attempts == startsBefore and #captions == 0,
    "repeated server heartbeat restarted music or repeated a client caption")
local previousEmitter = active().emitter
local replacementData = setmetatable({}, { __index = data })
device.getDeviceData = function() return replacementData end
Events.OnServerCommand.fire(ABRRadio.NET_MODULE, "MusicState", {
    id = "whole", sequence = S.sequence + 1000, phase = "play",
})
advance(delta)
assert(previousEmitter.returned and active().data == replacementData and #attempts == startsBefore + 1,
    "replacement radio data did not settle into one fresh receiver state")
Events.OnServerCommand.fire(ABRRadio.NET_MODULE, "MusicState", {
    id = "whole", sequence = S.sequence + 1000, phase = "play",
})
advance(delta)
assert(#attempts == startsBefore + 1, "replacement receiver restarted on the next heartbeat")
local commandVersion = C.packetVersion
Events.OnServerCommand.fire(ABRRadio.NET_MODULE, "MusicState", {
    id = "whole", sequence = S.sequence + 1000, phase = "announce",
})
assert(C.packetVersion == commandVersion, "out-of-order phase replaced command snapshot")
on = false
advance(delta)
advance(M.getHeartbeatTimeout() + 1)
on = true
advance(delta)
assert(C.devices[device] == nil, "discovery revived an expired command snapshot")
device.getDeviceData = function() return data end
-- Long-range acceleration must compose with the 50% transition gain, while
-- portable profiles whose nominal propagation is exactly 60 yards stay unchanged.
on, volume, distance = true, 1, 0
local transitionSequence = S.sequence + 2000
heartbeat("whole", transitionSequence, "play")
advance(5.1)
baseSpeakerRange, portableSpeaker = 15, true
local portableMidpoint = (M.PROPAGATION_RANGE + M.FULL_VOLUME_RANGE) * M.PORTABLE_SPEAKER_SCALE / 2
distance = math.sqrt(portableMidpoint^2 - 0.5^2) - 0.5
advance(delta)
assert(math.abs(active().emitter.gain - 0.0735) < 0.000001,
    "60-yard profile did not apply only the universal 1.3 rate")
portableSpeaker = false
distance = math.sqrt(midway^2 - 0.5^2) - 0.5
advance(delta)
local beforeTransition = active().emitter.gain
assert(math.abs(beforeTransition - 0.0484) < 0.000001)
heartbeat("whole", transitionSequence, "transition")
advance(10)
assert(math.abs(active().emitter.gain - beforeTransition * 0.5) < 0.000001,
    "long-range attenuation did not respect the half-volume transition")
cleanup()
print("PASS: receiver lifecycle, arbitration, round-robin, lag-independent playback, natural completion, microphone protection/restoration and discovery budget")
