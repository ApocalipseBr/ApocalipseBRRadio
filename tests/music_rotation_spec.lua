-- Runs with the native API fixture from music_spec.lua.
local S, M = ABRRadioMusicServer, ABRRadio.music
local originalClock, originalRand = getTimestampMs, ZombRand
local originalAcquire, originalRadio = ABRRadioServer.tryAcquireChannel, ABRRadio.getRadio
local now, canAcquire, roll = 0, true, 0
function getTimestampMs() return now end
function ZombRand(min, max) return max and min or math.min(roll, min - 1) end
ABRRadioServer.tryAcquireChannel = function(id, owner)
    if canAcquire then ABRRadioServer.channelOwners[id] = owner end
    return canAcquire
end
ABRRadio.getRadio = function() return { SendTransmission = function() end } end
ABRRadio.registerMusicStation({ id = "rotation", name = "Rotation", frequency = 94800 })
for i, weight in ipairs({ 1, 3, 6 }) do
    ABRRadio.registerSong({ id = "rotation_" .. i, station = "rotation",
        sound = "rotation_" .. i, duration = 1, weight = weight })
end
M.stationIds = { "rotation" }
S.ready, S.scanIndex, S.waitTicks, S.fastStations = true, 1, 0, 0
local function step(seconds)
    now = now + (seconds or 0) * 1000
    S.waitTicks = 0
    Events.OnTick.fire()
end
local function finish()
    step(3) -- announcement -> play
    step(1) -- play -> end
    step(5) -- end -> next content (or idle)
end
local function current() return S.states.rotation.entry end

-- Weighted selection includes only unused IDs, even for a single-song pool.
local pool = M.stations.rotation.songs
roll = 1
assert(M.pick(pool, nil, { rotation_1 = true }).id == "rotation_2")
roll = 3
assert(M.pick(pool, nil, { rotation_1 = true }).id == "rotation_3")
assert(M.pick({ pool[1] }, nil, { rotation_1 = true }) == nil)
roll = 0
canAcquire = false
step()
assert(S.playedSongs.rotation == nil, "channel contention consumed random history")
canAcquire = true
step()
assert(current().id == "rotation_1" and S.playedSongs.rotation.rotation_1)
finish()
assert(current().id == "rotation_2", "random selection repeated a played song")

-- Disable/re-enable retains history, including an interrupted song.
ABRRadio.channels.rotation.enabled = false
step()
assert(current() == nil and S.playedSongs.rotation.rotation_2)
ABRRadio.channels.rotation.enabled = true
step()
assert(current().id == "rotation_3")
finish()
assert(current() == nil and S.states.rotation.waitReason == "session_songs_exhausted")
assert(ABRRadioServer.channelOwners.rotation == nil, "exhausted station retained channel")
local sequence = S.sequence
step(60)
assert(current() == nil and S.sequence == sequence, "exhaustion restarted random rotation")

-- Requests bypass history and do not consume a song's future random play.
ABRRadio.registerSong({ id = "rotation_new", station = "rotation", sound = "new", duration = 1 })
assert(S.queueSongs("rotation", { "rotation_1", "rotation_1", "rotation_new" }, "Alice", ""))
step()
assert(current().id == "rotation_1")
finish()
assert(current().id == "rotation_1", "explicit repeat was blocked")
finish()
assert(current().id == "rotation_new" and not S.playedSongs.rotation.rotation_new)
finish()
assert(current().id == "rotation_new" and S.playedSongs.rotation.rotation_new,
    "requested song lost its random eligibility")
finish()
assert(current() == nil)

-- A fresh controller for the next session has no persisted rotation history.
local originalEvents = Events
local freshTick, freshLoad
Events = { OnTick = { Add = function(fn) freshTick = fn end },
    OnLoadRadioScripts = { Add = function(fn) freshLoad = fn end } }
dofile("Contents/mods/ApocalipseBRRadio/common/media/lua/server/ApocalipseBRRadio/ABRRadioMusicServer.lua")
Events = originalEvents
local fresh = ABRRadioMusicServer
freshLoad()
fresh.waitTicks = 0
freshTick()
assert(fresh.states.rotation.entry.id == "rotation_1", "new session retained played songs")
ABRRadioMusicServer = S
getTimestampMs, ZombRand = originalClock, originalRand
ABRRadioServer.tryAcquireChannel, ABRRadio.getRadio = originalAcquire, originalRadio
print("PASS: session random rotation, weights, exhaustion, requests and restart")
