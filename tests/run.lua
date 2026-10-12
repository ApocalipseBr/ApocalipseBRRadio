-- Fengari can print an uncaught error without returning a failing exit code.
local ok, err = xpcall(function()
    dofile("tests/music_spec.lua")
    dofile("tests/jukebox_spec.lua")
    dofile("tests/music_attraction_spec.lua")
end, debug.traceback)
if not ok then
    io.stderr:write(err .. "\n")
    os.exit(1)
end
