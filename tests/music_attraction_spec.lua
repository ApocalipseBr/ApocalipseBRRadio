local root = "Contents/mods/ApocalipseBRRadio/common/media/lua/"
package.path = root .. "server/?.lua;" .. package.path
local client, server, now = true, true, 1000
function isClient() return client end
function isServer() return server end
function getTimestampMs() return now end
local handler
Events = { OnTick = { Add = function(fn) handler = fn end } }
local path = root .. "server/ApocalipseBRRadio/ABRRadioMusicAttraction.lua"
dofile(path)
assert(not handler, "Clients must never emit AI noise")
client = false
local enabled, on, level, headphones, media, blocked = true, true, 1, -1, false, false
local frequency, placed, installed, dead = 94400, true, true, false
local state = { entry = { kind = "song" }, phase = "play" }
ABRRadio = { music = { stationIds = { "lure", "normal" },
    stations = { lure = { attractZombies = true }, normal = {} },
    ZOMBIE_SOUND_RADIUS = 100, ZOMBIE_SOUND_VOLUME = 60 },
    getChannelIdByFrequency = function(freq) return freq == 94400 and "lure" or "normal" end,
    isChannelEnabled = function() return enabled end }
ABRRadioMusicServer = { ready = true, states = { lure = state, normal = state } }
package.loaded["ApocalipseBRRadio/ABRRadioMusicServer"] = true
local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end
local data = { getIsTurnedOn = function() return on end,
    getDeviceVolume = function() return level end, getChannel = function() return frequency end,
    getHeadphoneType = function() return headphones end,
    isPlayingMedia = function() return media end, isNoTransmit = function() return blocked end }
local device = { getDeviceData = function() return data end,
    getSquare = function() return placed and {} or nil end,
    getObjectIndex = function() return placed and 0 or -1 end,
    getX = function() return 12.9 end, getY = function() return -3.2 end,
    getZ = function() return 0 end }
local equipped = device
local player = { getEquipedRadio = function() return equipped end,
    getClothingItem_Back = function() return nil end,
    getPrimaryHandItem = function() return equipped end,
    getSecondaryHandItem = function() return nil end,
    isDead = function() return dead end, getSquare = device.getSquare,
    getX = device.getX, getY = device.getY, getZ = device.getZ }
function instanceof(item, kind) return item == device and kind == "Radio" end
local part = { getDeviceData = device.getDeviceData,
    getInventoryItem = function() return installed and {} or nil end }
local vehicle = { isRemovedFromWorld = function() return not placed end,
    getPartById = function() return part end, getSquare = device.getSquare,
    getX = device.getX, getY = device.getY, getZ = device.getZ }
local world, players, vehicles = { device }, {}, {}
function getZomboidRadio() return { getDevices = function() return list(world) end } end
function getOnlinePlayers() return list(players) end
function getNumActivePlayers() return #players end
function getSpecificPlayer(i) return players[i + 1] end
function getCell()
    return { getVehicles = function() return { iterator = function()
        local i = 0
        return { hasNext = function() return i < #vehicles end,
            next = function() i = i + 1; return vehicles[i] end }
    end } end }
end
local sounds = {}
WorldSoundManager = { instance = { addSoundRepeating = function(_, source, x, y, z, radius, volume, stress)
    assert(x == 12 and y == -4 and z == 0 and stress == false)
    sounds[#sounds + 1] = { source = source, radius = radius, volume = volume }
end } }
dofile(path)
local function pulse(expected)
    local before = #sounds
    now = now + 1000
    handler()
    assert(#sounds - before == expected, "Unexpected number of AI sounds")
end
pulse(1)
assert(sounds[1].source == device and sounds[1].radius == 100 and sounds[1].volume == 60)
handler(); assert(#sounds == 1, "Unthrottled sound")
ABRRadioMusicServer.ready = false; pulse(0); ABRRadioMusicServer.ready = true
level = 0.5; pulse(1); assert(sounds[2].radius == 50 and sounds[2].volume == 30)
level = 0; pulse(0); level = 1
on = false; pulse(0); on = true
frequency = 94200; pulse(0); frequency = 94400
enabled = false; pulse(0); enabled = true
media = true; pulse(0); media = false
blocked = true; pulse(0); blocked = false
placed = false; pulse(0); placed = true
for _, phase in ipairs({ "announce", "end", "stop" }) do state.phase = phase; pulse(0) end
state.phase = "transition"; pulse(1)
state.entry.kind = "talk"; pulse(0); state.entry.kind = "song"
state.entry = nil; pulse(0); state.entry = { kind = "song" }
world, players, vehicles = {}, { player }, { vehicle }
state.phase = "play"; pulse(2)
assert(sounds[#sounds - 1].source == player and sounds[#sounds].source == vehicle)
headphones = 0; pulse(1); headphones = -1
installed = false; pulse(1); installed = true
dead = true; pulse(1); dead = false
equipped = nil; pulse(1); equipped = device
server = false; pulse(2)
print("PASS: server/SP receiver AI noise, siren radius, volume, headphones and lifecycle gates")
