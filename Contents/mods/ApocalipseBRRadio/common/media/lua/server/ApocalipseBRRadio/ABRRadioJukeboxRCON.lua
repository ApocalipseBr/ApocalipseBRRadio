if isClient() then return end
require "ApocalipseBRRadio/ABRRadioMusicServer"

-- Optional transport: radio playback also works without the RCON extension.
local available = pcall(require, "ApocBRRCON")
if not available or not ApocBRRCON then return end

ABRRadioJukeboxRCON = {}
local R = ABRRadioJukeboxRCON

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- station##player##songId,songId,...##message
-- Song references accept catalog IDs or registered whole-song sound names.
-- Only the first three separators are structural; message can contain ##.
function R.queue(payload, context)
    local function reject(reason)
        print("[ABRRadio Jukebox] Rejected requestId=" .. tostring(context and context.requestId) .. ": " .. reason)
        return false, reason
    end
    if type(payload) ~= "string" or #payload > 2048 then return reject("Invalid payload") end
    local fields, offset = {}, 1
    for i = 1, 3 do
        local boundary = payload:find("##", offset, true)
        if not boundary then return reject("Expected station##player##songIds##message") end
        fields[i] = trim(payload:sub(offset, boundary - 1))
        offset = boundary + 2
    end
    local songs = {}
    for song in (fields[3] .. ","):gmatch("(.-),") do
        song = trim(song)
        if song == "" then return reject("Empty song ID") end
        songs[#songs + 1] = song
    end
    local ok, result = ABRRadioMusicServer.queueSongs(fields[1], songs, fields[2], trim(payload:sub(offset)))
    if not ok then return reject(result) end
    print("[ABRRadio Jukebox] Queued " .. #songs .. " songs on " .. fields[1]
        .. "; pending=" .. result .. "; requestId=" .. tostring(context and context.requestId))
    return true, result
end

ApocBRRCON.subscribe("Jukebox", "Queue", R.queue)

-- station##[seconds|]message1##[seconds|]message2...
-- The signed adjustment controls the pause AFTER its message (default 3s).
function R.queueAnnouncer(payload, context)
    local function reject(reason)
        print("[ABRRadio Announcer] Rejected requestId=" .. tostring(context and context.requestId) .. ": " .. reason)
        return false, reason
    end
    if type(payload) ~= "string" or #payload > 16384 then return reject("Invalid payload") end
    local boundary = payload:find("##", 1, true)
    if not boundary then return reject("Expected station##message1[##message2...]") end
    local stationId = trim(payload:sub(1, boundary - 1))
    local messages, offset = {}, boundary + 2
    while true do
        boundary = payload:find("##", offset, true)
        local field = trim(boundary and payload:sub(offset, boundary - 1) or payload:sub(offset))
        local timing, text = field:match("^([^|]*)|(.*)$")
        if timing and trim(timing):match("^[%+%-]?[%d%.]+$") then
            local adjustment = tonumber(trim(timing))
            if not adjustment then return reject("Invalid announcer interval adjustment") end
            messages[#messages + 1] = { text = trim(text), intervalAdjustment = adjustment }
        else
            messages[#messages + 1] = field
        end
        if #messages > ABRRadioMusicServer.MAX_BATCH then return reject("Invalid batch size") end
        if not boundary then break end
        offset = boundary + 2
    end
    local ok, result = ABRRadioMusicServer.queueAnnouncerMessages(stationId, messages)
    if not ok then return reject(result) end
    print("[ABRRadio Announcer] Queued " .. #messages .. " messages on " .. stationId
        .. "; pending=" .. result .. "; requestId=" .. tostring(context and context.requestId))
    return true, result
end

ApocBRRCON.subscribe("Radio", "QueueAnnouncer", R.queueAnnouncer)
