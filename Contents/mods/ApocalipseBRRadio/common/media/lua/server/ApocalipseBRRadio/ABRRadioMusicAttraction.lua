if isClient() then return end
require "ApocalipseBRRadio/ABRRadioMusicServer"

-- AI noise belongs to the authority, never to each client's FMOD emitter.
-- Receivers remain noisy without a nearby hearing player, while loaded.
local M, S = ABRRadio.music, ABRRadioMusicServer
local checkedAt = 0

local function emit(device, source, inventory)
    if not device or not source or not source:getSquare() then return end
    local data = device:getDeviceData()
    if not data or not data:getIsTurnedOn() or data:getDeviceVolume() <= 0
        or data:isPlayingMedia() or data:isNoTransmit()
        or (inventory and data:getHeadphoneType() >= 0) then return end
    local id = ABRRadio.getChannelIdByFrequency(data:getChannel())
    local station = id and M.stations[id]
    local state = id and S.states[id]
    if not station or station.attractZombies ~= true or not ABRRadio.isChannelEnabled(id)
        or not state or not state.entry or state.entry.kind ~= "song"
        or (state.phase ~= "play" and state.phase ~= "transition") then return end
    local level = math.min(1, data:getDeviceVolume())
    local radius = math.max(1, math.floor(M.ZOMBIE_SOUND_RADIUS * level))
    local volume = math.max(1, math.floor(M.ZOMBIE_SOUND_VOLUME * level))
    WorldSoundManager.instance:addSoundRepeating(source,
        math.floor(source:getX()), math.floor(source:getY()), math.floor(source:getZ()),
        radius, volume, false)
end

local function tick()
    if not S.ready then return end
    local now = getTimestampMs()
    if now - checkedAt < 1000 then return end
    checkedAt = now
    local enabled = false
    for _, id in ipairs(M.stationIds) do
        if M.stations[id].attractZombies == true and ABRRadio.isChannelEnabled(id) then
            enabled = true; break
        end
    end
    if not enabled then return end
    -- Placed receivers register with ZomboidRadio on both server and client.
    local devices = getZomboidRadio():getDevices()
    for i = 0, devices:size() - 1 do
        local device = devices:get(i)
        if not device.getVehicle and not device.getPlayer and device:getObjectIndex() >= 0 then
            emit(device, device, false)
        end
    end
    local function visitPlayer(player)
        if not player or player:isDead() then return end
        local device
        if isServer() then
            -- getEquipedRadio is cached by updateTextObjects, which skips the
            -- dedicated server. Inspect synchronized equipment instead.
            local back = player:getClothingItem_Back()
            local primary = player:getPrimaryHandItem()
            local secondary = player:getSecondaryHandItem()
            if back and instanceof(back, "Radio") then device = back
            elseif primary and instanceof(primary, "Radio") then device = primary
            elseif secondary and instanceof(secondary, "Radio") then device = secondary end
        else
            device = player:getEquipedRadio()
        end
        emit(device, player, true)
    end
    if isServer() then
        local players = getOnlinePlayers()
        for i = 0, players:size() - 1 do visitPlayer(players:get(i)) end
    else
        for i = 0, getNumActivePlayers() - 1 do visitPlayer(getSpecificPlayer(i)) end
    end
    -- Vehicle radios are not registered in ZomboidRadio's device list.
    local cell = getCell()
    if cell then
        local vehicles = cell:getVehicles():iterator()
        while vehicles:hasNext() do
            local vehicle = vehicles:next()
            if not vehicle:isRemovedFromWorld() then
                local part = vehicle:getPartById("Radio")
                if part and part:getInventoryItem() then emit(part, vehicle, false) end
            end
        end
    end
end

Events.OnTick.Add(tick)
