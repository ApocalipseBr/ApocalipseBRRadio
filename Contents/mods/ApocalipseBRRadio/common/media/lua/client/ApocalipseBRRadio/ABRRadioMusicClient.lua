if isServer() then return end
require "ApocalipseBRRadio/ABRRadioMusic"

ABRRadioMusicClient = { devices = {}, fading = {}, muted = {}, clock = 0,
    stations = {}, packetVersion = 0 }
local C, M = ABRRadioMusicClient, ABRRadio.music
local phaseOrder = { announce = 1, play = 2, transition = 3, ["end"] = 4, stop = 5 }
local musicFrequencies, stationCount = {}, 0
local worldCursor, inventoryCursors, squareCursors = 0, {}, {}
local SCAN_BUDGET = 8
local MUSIC_RANGE = M.LISTEN_RANGE

local function refreshFrequencies()
    -- Registrations are append-only; no station traversal on ordinary ticks.
    while stationCount < #M.stationIds do
        stationCount = stationCount + 1
        musicFrequencies[M.stations[M.stationIds[stationCount]].frequency] = true
    end
end

local function nearby(device)
    local object = device
    if device.getPlayer then
        local owner = device:getPlayer()
        for i = 0, getNumActivePlayers() - 1 do
            if owner and owner == getSpecificPlayer(i) then return true end
        end
        object = device:getWorldItem()
        if not object then return false end
    end
    if device.getVehicle then
        object = device:getVehicle()
        if not object or object:isRemovedFromWorld() or not device:getInventoryItem() then return false end
    elseif not device.getPlayer and device:getObjectIndex() < 0 then
        return false
    end
    if not object:getSquare() then return false end
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and math.abs(player:getX() - object:getX()) <= 5
            and math.abs(player:getY() - object:getY()) <= 5
            and math.abs(player:getZ() - object:getZ()) <= 1 then return true end
    end
    return false
end

local function protect(device, inventory)
    local data = device:getDeviceData()
    -- Playback discovery uses the music range; microphone protection keeps its
    -- native local neighbourhood and must not limit distant speaker playback.
    if data and musicFrequencies[data:getChannel()] and C.applyState then C.applyState(device) end
    if data and musicFrequencies[data:getChannel()] and (inventory or nearby(device)) then
        local saved = C.muted[device]
        if saved and saved.data ~= data then
            saved.data:setMicIsMuted(saved.original)
            C.muted[device] = nil
            saved = nil
        end
        if not saved then
            C.muted[device] = { data = data, original = data:getMicIsMuted(), inventory = inventory }
        else
            saved.inventory = inventory
        end
        if not data:getMicIsMuted() then data:setMicIsMuted(true) end
    end
end

local function scanList(list, cursor, visit)
    local size = list:size()
    if size == 0 then return 0 end
    for _ = 1, math.min(SCAN_BUDGET, size) do
        if cursor >= size then cursor = 0 end
        visit(list:get(cursor))
        cursor = cursor + 1
    end
    return cursor
end

local function visitWorld(device) protect(device, false) end
local function visitItem(item)
    if instanceof(item, "Radio") then protect(item, true) end
end
local function scanSquares(cell, player, cursor)
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    -- Match the native VOIP neighbourhood: 9x9 squares on two levels.
    for _ = 1, 4 do
        local square = cell:getGridSquare(x + cursor % 9 - 4,
            y + math.floor(cursor / 9) % 9 - 4, z + math.floor(cursor / 81) - 1)
        cursor = (cursor + 1) % 162
        if square then
            local vehicle = square:getVehicleContainer()
            if vehicle then
                local part = vehicle:getPartById("Radio")
                if part then protect(part, false) end
            end
            local objects = square:getWorldObjects()
            for j = 0, objects:size() - 1 do
                local item = objects:get(j):getItem()
                if item and instanceof(item, "Radio") then protect(item, false) end
            end
        end
    end
    return cursor
end

local function guardTransmission()
    refreshFrequencies()
    if stationCount == 0 then return end
    -- Bounded discovery: eight registered devices/items and four squares.
    worldCursor = scanList(getZomboidRadio():getDevices(), worldCursor, visitWorld)
    local cell = getCell()
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player then
            inventoryCursors[i] = scanList(player:getInventory():getItems(), inventoryCursors[i] or 0, visitItem)
            if cell then squareCursors[i] = scanSquares(cell, player, squareCursors[i] or 0) end
        end
    end
    for device, saved in pairs(C.muted) do
        local data = device:getDeviceData()
        local present = saved.inventory and device:getPlayer()
        local localOwner = false
        if present then
            for i = 0, getNumActivePlayers() - 1 do
                if present == getSpecificPlayer(i) then localOwner = true; break end
            end
        end
        if data ~= saved.data or not musicFrequencies[saved.data:getChannel()]
            or (saved.inventory and not localOwner) or (not saved.inventory and not nearby(device)) then
            saved.data:setMicIsMuted(saved.original)
            C.muted[device] = nil
        elseif not data:getMicIsMuted() then
            data:setMicIsMuted(true)
        end
    end
end

local function stop(state)
    if state.emitter and state.handle then state.emitter:stopSoundLocal(state.handle) end
    if state.emitter then
        -- We own this emitter, never the device's static/VOIP emitter.
        state.emitter:stopAll()
        getWorld():returnOwnershipOfEmitter(state.emitter)
    end
    state.emitter, state.handle = nil, nil
    state.spatial, state.volume = nil, nil
end

local function fade(device, state, mode)
    state.ended = true
    if not state.emitter then
        local tail = C.fading[device]
        if mode == "stop" and tail then
            tail.mode, tail.startedAt, tail.fromGain = "stop", C.clock, tail.gain
        end
        return
    end
    if not state.handle then stop(state); return end
    if C.fading[device] then stop(C.fading[device]) end
    C.fading[device] = {
        emitter = state.emitter, handle = state.handle, data = state.data,
        station = state.entry.station, startedAt = C.clock,
        mode = mode or "hold", frames = state.transitionFrames or 0,
        fromGain = state.transitionFrom or state.gain or 0.5,
        gain = state.gain or 0.5,
    }
    state.emitter, state.handle = nil, nil
end

local function position(device)
    if device.getPlayer then
        local owner = device:getPlayer()
        if not owner or owner:isDead() or owner:getEquipedRadio() ~= device then return nil end
        return owner:getX(), owner:getY(), owner:getZ(), owner
    end
    if device.getVehicle then
        local vehicle = device:getVehicle()
        if not vehicle or vehicle:isRemovedFromWorld() or not vehicle:getSquare()
            or not device:getInventoryItem() then return nil end
        return vehicle:getX(), vehicle:getY(), vehicle:getZ(), nil
    end
    -- Picking up/unloading a placed receiver invalidates the old world object.
    if not device:getSquare() or device:getObjectIndex() < 0 then return nil end
    return device:getX() + 0.5, device:getY() + 0.5, device:getZ(), nil
end

local function speakerProfile(device, data)
    local category, scale = "stationary", M.STATIONARY_SPEAKER_SCALE
    if device.getVehicle then
        category, scale = "vehicle", M.VEHICLE_SPEAKER_SCALE
    elseif data:getIsPortable() then
        category = data:getIsTwoWay() and "walkie_talkie" or "hand_radio"
        scale = M.PORTABLE_SPEAKER_SCALE
    end
    local strength = math.min(1, math.max(0, data:getBaseVolumeRange() / M.SPEAKER_REFERENCE_RANGE)) * scale
    return math.min(1, strength), category
end

local function audible(device, data)
    if not data:getIsTurnedOn() or data:getDeviceVolume() <= 0
        or data:isPlayingMedia() or data:isNoTransmit() then return false end
    local x, y, z, owner = position(device)
    if not x then return false end
    local range = MUSIC_RANGE
    -- Audible propagation shrinks with volume; receiver lifetime stays fixed.
    local level = math.min(1, math.max(0, data:getDeviceVolume()))
    local strength = speakerProfile(device, data)
    local propagationRange = M.PROPAGATION_RANGE * level * strength
    local fullVolumeRange = M.FULL_VOLUME_RANGE * level * strength
    local falloffRate = M.GLOBAL_FALLOFF_RATE
        * (propagationRange > M.FASTER_FALLOFF_THRESHOLD + 0.000001
            and M.LONG_RANGE_FALLOFF_RATE or 1)
    local nearestGain
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and not player:isDead() and not player:hasTrait(CharacterTrait.DEAF) then
            if owner and data:getHeadphoneType() >= 0 then
                if player == owner then return true, x, y, z, 1 end
            else
                local distanceSquared = (player:getX() - x)^2 + (player:getY() - y)^2
                    + ((player:getZ() - z) * 3)^2
                if distanceSquared <= range^2 then
                    local falloff = 0
                    if propagationRange > 0 then
                        local progress = (math.sqrt(distanceSquared) - fullVolumeRange)
                            / (propagationRange - fullVolumeRange)
                        falloff = math.min(1, math.max(0, 1 - progress * falloffRate))
                    end
                    local gain = strength * falloff ^ M.DISTANCE_FALLOFF_POWER
                    nearestGain = math.max(nearestGain or 0, gain)
                end
            end
        end
    end
    if nearestGain ~= nil then return true, x, y, z, nearestGain end
    return false
end

local function onDeviceText(guid, codes, x, y, z, text, device, skipProtection)
    local id, sequence, phase = M.decode(codes)
    if not id or not device or not device.getDeviceData then return end
    local entry = M.content[id]
    if not entry then return end
    local data = device:getDeviceData()
    local station = M.stations[entry.station]
    refreshFrequencies()
    if not skipProtection then protect(device, device.getPlayer ~= nil) end
    if not station or not data or data:getChannel() ~= station.frequency or not audible(device, data) then return end
    local state = C.devices[device]
    if state and sequence < state.sequence then return end
    if state and sequence == state.sequence then
        if state.entry.id ~= id or phaseOrder[phase] < phaseOrder[state.phase] then return end
    end
    if not state or state.sequence ~= sequence or state.data ~= data then
        if state then
            if state.data == data then fade(device, state) else stop(state) end
        end
        state = { entry = entry, sequence = sequence, data = data, chunk = 0 }
        C.devices[device] = state
    end
    -- Heartbeats announce state; their absence never interrupts an active file.
    -- An ended local file retains its sequence so repeats cannot restart it.
    state.phase = phase
    if phase == "transition" and not state.transitionFrames then
        state.transitionFrames, state.transitionFrom = 0, state.gain or 0.5
    end
    if phase == "end" then fade(device, state) end
    if phase == "stop" then fade(device, state, "stop") end
end

function C.applyState(device)
    local data = device:getDeviceData()
    if not data then return end
    local packet = C.stations[data:getChannel()]
    if not packet or C.clock - packet.receivedAt > M.getHeartbeatTimeout() then return end
    local state = C.devices[device]
    if state and state.packetVersion == packet.version then return end
    -- Applying a cached packet must not recursively run discovery/protection.
    onDeviceText("", M.encode(packet.id, packet.sequence, packet.phase), 0, 0, 0, "", device, true)
    state = C.devices[device]
    if state and state.sequence == packet.sequence then
        state.packetVersion = packet.version
    end
end

function C.receiveState(packet)
    if type(packet) ~= "table" or type(packet.id) ~= "string"
        or type(packet.sequence) ~= "number" or packet.sequence < 0
        or packet.sequence ~= math.floor(packet.sequence) or not phaseOrder[packet.phase] then return end
    local entry = M.content[packet.id]
    if not entry then
        if C.missingContent ~= packet.id then
            print("[ABRRadio Music Client] Missing catalog entry: " .. packet.id .. "; update the Music Pack.")
            C.missingContent = packet.id
        end
        return
    end
    local station = M.stations[entry.station]
    if not station then return end
    local previous = C.stations[station.frequency]
    if previous and (packet.sequence < previous.sequence
        or (packet.sequence == previous.sequence and (packet.id ~= previous.id
            or phaseOrder[packet.phase] < phaseOrder[previous.phase]))) then return end
    if not previous or previous.sequence ~= packet.sequence or previous.phase ~= packet.phase then
        print("[ABRRadio Music Client] Received: " .. entry.station .. " @ " .. station.frequency
            .. "; content=" .. packet.id .. "; phase=" .. packet.phase)
    end
    C.packetVersion = C.packetVersion + 1
    C.stations[station.frequency] = { id = packet.id, sequence = packet.sequence,
        phase = packet.phase, receivedAt = C.clock, version = C.packetVersion }
    for device in pairs(C.devices) do C.applyState(device) end
    for device in pairs(C.muted) do C.applyState(device) end
end

local function play(device, state, elapsed)
    if state.entry.kind ~= "song" or (C.fading[device] and C.fading[device].mode == "stop")
        or (state.retryAt and C.clock < state.retryAt) then return end
    local entry = state.entry
    -- Prefer a whole-file sound. Legacy chunk-only catalogs start at chunk one
    -- and advance on this receiver's own playback clock.
    local chunks = not entry.sound and entry.chunks
    if not chunks and state.handle then return end -- same airing never restarts on heartbeat
    local index = chunks and M.chunkIndex(entry, elapsed) or 1
    if index == 0 or index <= state.chunk then return end
    if state.handle then
        state.emitter:stopSoundLocal(state.handle)
        state.handle = nil
    end
    if not state.emitter then
        local x, y, z = position(device)
        state.emitter = getWorld():getFreeEmitter(x, y, z)
        getWorld():takeOwnershipOfEmitter(state.emitter)
    end
    local sound = chunks and chunks[index].sound or entry.sound
    -- The three-argument local overload avoids the nullable overload ambiguity
    -- and, crucially, never sends PlayWorldSound to other clients. Each client
    -- renders one local copy per receiver.
    local handle = state.emitter:playSoundImpl(sound, false, nil)
    if not handle or handle <= 0 then
        -- Zero is truthy in Lua. Retry at a bounded rate without advancing the
        -- chunk or declaring playback successful.
        state.retryAt = C.clock + M.PLAY_RETRY
        if not state.failureReported then
            print("[ABRRadio Music] Could not start sound: " .. tostring(sound))
            state.failureReported = true
        end
        stop(state)
        return
    end
    state.handle, state.chunk, state.retryAt = handle, index, nil
    state.spatial, state.volume = nil, nil
    state.startedAt = state.startedAt or C.clock
    if not state.fadeInFrames then
        state.fadeInFrames = 0
        state.emitter:setVolume(handle, device:getDeviceData():getDeviceVolume() * 0.5)
        local tail = C.fading[device]
        if tail then
            tail.mode, tail.frames, tail.fromGain = "crossfade", 0, tail.gain
        end
    end
    local strength, category = speakerProfile(device, device:getDeviceData())
    print("[ABRRadio Music Client] Audio started: " .. state.entry.station
        .. "; content=" .. state.entry.id .. "; sequence=" .. state.sequence
        .. "; receiver=" .. tostring(device) .. "; device=" .. category
        .. "; speaker_strength=" .. string.format("%.2f", strength) .. "; sound=" .. sound)
end

local function updateAudio(device, state, data, gain, x, y, z, distanceGain)
    state.emitter:setPos(x, y, z)
    if state.handle then
        local spatial = false
        if state.spatial ~= spatial then
            state.emitter:set3D(state.handle, spatial)
            state.spatial = spatial
        end
        -- Centered playback uses the same distance curve for cars/world radios.
        local volume = data:getDeviceVolume() * gain * distanceGain
        if state.volume ~= volume then
            state.emitter:setVolume(state.handle, volume)
            state.volume = volume
        end
    end
    state.emitter:tick()
end

local function tick()
    guardTransmission()
    C.clock = C.clock + getGameTime():getRealworldSecondsSinceLastUpdate()
    -- Kahlua does not expose Lua's next(). Empty tables already skip pairs loops.
    for device, tail in pairs(C.fading) do
        local data = device:getDeviceData()
        tail.frames = tail.frames + 1
        local gain
        if tail.mode == "hold" then
            gain = tail.fromGain + (0.5 - tail.fromGain) * math.min(1, tail.frames / M.FADE_OUT_FRAMES)
        elseif tail.mode == "crossfade" then
            gain = tail.fromGain * math.max(0, 1 - tail.frames / M.FADE_IN_FRAMES)
        else
            gain = tail.fromGain * math.max(0, 1 - (C.clock - tail.startedAt) / M.FADE_DURATION)
        end
        tail.gain = gain
        local canHear, x, y, z, distanceGain
        if data and data == tail.data and data:getChannel() == M.stations[tail.station].frequency then
            canHear, x, y, z, distanceGain = audible(device, data)
        end
        if not data or data ~= tail.data or data:getChannel() ~= M.stations[tail.station].frequency
            or not canHear or not tail.emitter:isPlaying(tail.handle) then
            stop(tail)
            C.fading[device] = nil
        else
            updateAudio(device, tail, data, gain, x, y, z, distanceGain)
            if gain == 0 then
                stop(tail)
                C.fading[device] = nil
            end
        end
    end
    for device, state in pairs(C.devices) do
        local data = device:getDeviceData()
        local canHear, x, y, z, distanceGain
        if data and data == state.data and data:getChannel() == M.stations[state.entry.station].frequency then
            canHear, x, y, z, distanceGain = audible(device, data)
        end
        if not data or data ~= state.data
            or data:getChannel() ~= M.stations[state.entry.station].frequency
            or not canHear then
            if state.handle then
                local reason = "out_of_range_or_unavailable"
                if not data or data ~= state.data then reason = "receiver_changed"
                elseif data:getChannel() ~= M.stations[state.entry.station].frequency then reason = "retuned"
                elseif not data:getIsTurnedOn() then reason = "powered_off"
                elseif data:getDeviceVolume() <= 0 then reason = "muted"
                elseif data:isPlayingMedia() then reason = "recorded_media"
                elseif data:isNoTransmit() then reason = "reception_blocked" end
                print("[ABRRadio Music Client] Released: " .. state.entry.station
                    .. "; content=" .. state.entry.id .. "; sequence=" .. state.sequence
                    .. "; receiver=" .. tostring(device) .. "; reason=" .. reason)
            end
            stop(state)
            C.devices[device] = nil
        else
            if state.handle and not state.emitter:isPlaying(state.handle) then
                stop(state)
                if state.entry.sound or state.chunk >= #(state.entry.chunks or {}) then
                    state.ended = true
                    print("[ABRRadio Music Client] Finished locally: " .. state.entry.station
                        .. "; content=" .. state.entry.id .. "; sequence=" .. state.sequence
                        .. "; receiver=" .. tostring(device))
                end
            end
            if (state.phase == "play" or state.phase == "transition") and not state.ended then
                if state.entry.kind == "song" then
                    local localElapsed = state.startedAt and (C.clock - state.startedAt) or 0
                    play(device, state, localElapsed)
                    if state.emitter then
                        local gain
                        if state.phase == "transition" then
                            state.transitionFrames = (state.transitionFrames or 0) + 1
                            gain = state.transitionFrom + (0.5 - state.transitionFrom)
                                * math.min(1, state.transitionFrames / M.FADE_OUT_FRAMES)
                        else
                            gain = 0.5 + 0.5 * math.min(1, (state.fadeInFrames or 0) / M.FADE_IN_FRAMES)
                            state.fadeInFrames = (state.fadeInFrames or 0) + 1
                        end
                        state.gain = gain
                        updateAudio(device, state, data, gain, x, y, z, distanceGain)
                    end
                end
            end
        end
    end
end

Events.OnDeviceText.Add(onDeviceText)
Events.OnServerCommand.Add(function(module, command, args)
    if module == ABRRadio.NET_MODULE and command == "MusicState" then C.receiveState(args) end
end)
Events.OnTick.Add(tick)
