-- Runs after jukebox_spec.lua using the real music controller and native API fixture.
local S, M = ABRRadioMusicServer, ABRRadio.music
local originalServer, originalClock = isServer, getTimestampMs
local originalRadio, originalAcquire = ABRRadio.getRadio, ABRRadioServer.tryAcquireChannel
local originalCommand = sendServerCommand
local originalEnabled = ABRRadio.isChannelEnabled
local now, observations = 0, {}
function isServer() return true end
function getTimestampMs() return now end
function sendServerCommand() end
ABRRadio.getRadio = function() return { SendTransmission = function() end } end
ABRRadioServer.tryAcquireChannel = function(id, owner)
    ABRRadioServer.channelOwners[id] = owner
    return true
end
ApocBRRadioBridge = {
    recordMusicState = function(...) observations[#observations + 1] = { "state", ... } end,
    recordListenerRequest = function(...) observations[#observations + 1] = { "request", ... } end,
    recordAiredLine = function(...) observations[#observations + 1] = { "line", ... } end,
}
local callbacks = ApocBRRadioBridge
ABRRadio.registerMusicStation({ id = "bridge_test", name = "Bridge", frequency = 94700 })
ABRRadio.registerSong({ id = "bridge_song", station = "bridge_test", sound = "BridgeSong", duration = 6, title = "Bridge song" })
M.stationIds = { "bridge_test" }
S.states.bridge_test = nil
S.ready, S.scanIndex, S.waitTicks, S.fastStations = true, 1, 0, 0
local function step(seconds)
    now = now + seconds * 1000
    S.waitTicks = 0
    Events.OnTick.fire()
end
local function count(kind, value)
    local total = 0
    for _, observation in ipairs(observations) do
        if observation[1] == kind and (not value
            or kind == "state" and observation[5] == value
            or kind == "line" and observation[3] == value) then total = total + 1 end
    end
    return total
end
assert(S.queueSongs("bridge_test", { "BridgeSong" }, "Alice", "Still here"))
assert(count("request") == 1, "accepted request missing observation")
assert(observations[1][4] == "bridge_song", "request did not report canonical song IDs")
assert(not S.queueSongs("bridge_test", { "missing" }, "Alice", "bad"))
assert(count("request") == 1, "rejected request emitted observation")
assert(S.queueAnnouncerMessages("bridge_test", { "Good evening" }))
step(0)
assert(count("state", "announced") == 1, "announcement transition missing")
step(1)
assert(count("state", "announced") == 1, "announcement heartbeat became another event")
step(2)
assert(count("state", "started") == 1, "play transition missing")
step(0.1)
assert(count("state", "started") == 1, "transition/heartbeat repeated started observation")
step(6)
assert(count("state", "completed") == 1, "completed transition missing")
step(0)
assert(count("state", "completed") == 1, "completion heartbeat repeated observation")
step(3)
assert(count("line", "dedication") == 1, "successful dedication transmission missing")
step(3)
assert(count("line", "announcer") == 1, "successful announcer transmission missing")
ABRRadio.isChannelEnabled = function(id) return id ~= "bridge_test" and originalEnabled(id) end
step(0)
assert(count("state", "stopped") == 1, "disabled playback did not publish stopped")
step(0)
assert(count("state", "stopped") == 1, "disabled idle repeated stopped")
ABRRadio.isChannelEnabled = originalEnabled
local total = #observations
ApocBRRadioBridge = nil
assert(S.queueSongs("bridge_test", { "bridge_song" }, "Alice", ""), "stock engine fallback failed")
step(3)
assert(#observations == total, "absent patch emitted observations")
ApocBRRadioBridge = { recordListenerRequest = function() error("fixture adapter failure") end,
    recordMusicState = function() error("fixture adapter failure") end,
    recordAiredLine = function() error("fixture adapter failure") end }
assert(S.queueSongs("bridge_test", { "bridge_song" }, "Alice", ""), "bridge error interrupted request")
step(3)
-- Single-player must not use the server-only bridge even if a test global exists.
function isServer() return false end
assert(S.queueSongs("bridge_test", { "bridge_song" }, "Alice", ""))
assert(#observations == total)
function isServer() return true end
ApocBRRadioBridge = callbacks
ABRRadio.registerMusicStation({ id = "bridge_talk", name = "Talk", frequency = 94750 })
ABRRadio.registerMusicTalk({ id = "bridge_catalog", station = "bridge_talk", duration = 10,
    lines = { { at = 0, text = "Catalog bulletin" } } })
M.stationIds, S.scanIndex = { "bridge_talk" }, 1
S.states.bridge_talk = { wantTalk = true }
step(0)
assert(count("line", "catalog_talk") == 1, "catalog line transmission missing observation")
ApocBRRadioBridge = nil
isServer, getTimestampMs = originalServer, originalClock
ABRRadio.getRadio, ABRRadioServer.tryAcquireChannel = originalRadio, originalAcquire
sendServerCommand = originalCommand
print("PASS: optional backend bridge request validation, playback transition deduplication, aired lines and failure isolation")
