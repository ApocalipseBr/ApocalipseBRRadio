-- Loaded in two independent Lua states to simulate two network clients.
local root = "Contents/mods/ApocalipseBRRadio/common/media/lua/"
package.path = root .. "shared/?.lua;" .. root .. "client/?.lua;" .. package.path
Scope = { x = 0, starts = 0, logs = {}, radios = {}, emitters = {} }
local T = Scope
next = nil -- Match the game's Kahlua globals, as in the main simulation.
function print(message) T.logs[#T.logs + 1] = message end
local function event()
    local handlers = {}
    return { Add = function(fn) handlers[#handlers + 1] = fn end,
        fire = function(...) for _, fn in ipairs(handlers) do fn(...) end end }
end
Events = { OnTick = event(), OnDeviceText = event(), OnServerCommand = event() }
function isClient() return true end
function isServer() return false end
function getText(key) return key end
function sendClientCommand() error("listener sent a music control command") end
function sendServerCommand() error("client broadcast music state") end
function instanceof() return false end
function getCell() return nil end
function getGameTime() return { getRealworldSecondsSinceLastUpdate = function() return 0.1 end } end
CharacterTrait = { DEAF = "deaf" }
local function list(items)
    return { size = function() return #items end, get = function(_, index) return items[index + 1] end }
end
T.player = { getX = function() return T.x end, getY = function() return 0 end,
    getZ = function() return 0 end, isDead = function() return false end,
    hasTrait = function() return false end,
    getInventory = function() return { getItems = function() return list({}) end } end }
function getNumActivePlayers() return 1 end
function getSpecificPlayer() return T.player end
for index = 1, 2 do
    local data = { on = index == 1, volume = 1, frequency = 94200, mic = false, base = 15 }
    function data:getIsTurnedOn() return self.on end
    function data:getDeviceVolume() return self.volume end
    function data:getChannel() return self.frequency end
    function data:isPlayingMedia() return false end
    function data:isNoTransmit() return false end
    function data:getBaseVolumeRange() return self.base end
    function data:getIsPortable() return false end
    function data:getIsTwoWay() return false end
    function data:getMicIsMuted() return self.mic end
    function data:setMicIsMuted(value) self.mic = value end
    local device = { data = data, getDeviceData = function() return data end,
        getSquare = function() return {} end, getObjectIndex = function() return index end,
        getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end }
    T.radios[index] = device
end
local radio = { getDevices = function() return list(T.radios) end }
function getZomboidRadio() return radio end
local world = {}
function world:getFreeEmitter()
    local emitter = {}
    function emitter:playSound() error("replicated music playback") end
    function emitter:stopSound() error("replicated music stop") end
    function emitter:playSoundImpl(sound, worldSound, parent)
        assert(worldSound == false and parent == nil, "playback escaped local scope")
        T.starts = T.starts + 1
        self.handle = T.starts
        return self.handle
    end
    function emitter:stopSoundLocal(handle)
        assert(handle == self.handle, "stopped a different receiver's handle")
        self.stopped = true
    end
    function emitter:stopAll() self.stopped = true end
    function emitter:isPlaying(handle) return handle == self.handle and not self.stopped and not self.finished end
    function emitter:setVolume(handle, volume)
        assert(handle == self.handle, "changed a different receiver's volume")
        self.gain = volume
    end
    function emitter:set3D(handle, spatial) assert(not spatial) end
    function emitter:setPos() end
    function emitter:tick() end
    T.emitters[#T.emitters + 1] = emitter
    return emitter
end
function world:takeOwnershipOfEmitter() end
function world:returnOwnershipOfEmitter(emitter) emitter.returned = true end
function getWorld() return world end
require "ApocalipseBRRadio/ABRRadioMusicClient"
ABRRadio.registerMusicStation({ id = "scope_station", frequency = 94200 })
ABRRadio.registerMusicStation({ id = "other_station", frequency = 95000 })
ABRRadio.registerSong({ id = "scope_song", station = "scope_station", sound = "ScopeSound", duration = 600 })
ABRRadio.registerSong({ id = "other_song", station = "other_station", sound = "OtherSound", duration = 600 })
T.client, T.music = ABRRadioMusicClient, ABRRadio.music
function T.packet(id, sequence, phase)
    Events.OnServerCommand.fire(ABRRadio.NET_MODULE, "MusicState", {
        id = id or "scope_song", sequence = sequence or 10, phase = phase or "play",
    })
end
function T.advance(seconds)
    for _ = 1, math.floor(seconds * 10 + 0.5) do Events.OnTick.fire() end
end
function T.active(index) return T.client.devices[T.radios[index or 1]] end
