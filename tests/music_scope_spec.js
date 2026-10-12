// Separate Lua VMs provide genuinely separate client globals, radio objects and emitters.
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

function execute(state, source) {
    if (lauxlib.luaL_dostring(state, to_luastring(source)) !== lua.LUA_OK) {
        throw new Error(to_jsstring(lua.lua_tostring(state, -1)));
    }
}
function client() {
    const state = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(state);
    if (lauxlib.luaL_dofile(state, to_luastring('tests/music_scope_fixture.lua')) !== lua.LUA_OK) {
        throw new Error(to_jsstring(lua.lua_tostring(state, -1)));
    }
    execute(state, 'Scope.packet(); Scope.advance(5.1); assert(Scope.active().emitter.gain == 1)');
    return state;
}
const a = client(), b = client();
try {
    execute(a, 'Original = Scope.active(); Emitter = Original.emitter; Handle = Original.handle; Started = Original.startedAt');
    execute(b, 'Scope.x = 220; Scope.advance(0.1); assert(Scope.active() == nil)');
    execute(a, 'Scope.advance(0.1); assert(Scope.active() == Original and Original.handle == Handle and Emitter.gain == 1 and not Emitter.stopped, "another listener leaving stopped nearby audio")');

    execute(b, 'Scope.x = 0; Scope.packet(); Scope.advance(5.1); Scope.radios[1].data.volume = 0.2; Scope.advance(0.1); assert(Scope.active().emitter.gain == 0.2)');
    execute(a, 'Scope.advance(0.1); assert(Emitter.gain == 1 and Original.handle == Handle, "another client changed local volume")');
    execute(b, 'Scope.radios[1].data.on = false; Scope.advance(0.1); assert(Scope.active() == nil)');
    execute(a, 'Scope.advance(0.1); assert(Scope.active() == Original and not Emitter.stopped, "another radio power-off stopped this client")');

    // Two radios in one client must also own separate handles and volume settings.
    execute(a, 'Scope.radios[2].data.on = true; Scope.packet(); Scope.advance(5.1); Other = Scope.active(2); assert(Other and Other.emitter ~= Emitter)');
    execute(a, 'Scope.radios[2].data.volume = 0.2; Scope.advance(0.1); assert(Other.emitter.gain == 0.2 and Emitter.gain == 1)');
    execute(a, 'Scope.radios[2].data.on = false; Scope.advance(0.1); assert(Other.emitter == nil and Scope.active() == Original and not Emitter.stopped)');

    // A stop for another station must not overwrite this station's airing.
    execute(a, 'Scope.packet("other_song", 50, "stop"); Scope.advance(0.1); assert(Scope.active() == Original and Original.handle == Handle and Emitter.gain == 1)');
    execute(b, 'Scope.radios[1].data.on = true; Scope.radios[1].data.volume = 1; Scope.packet(); Scope.advance(5.1); BEmitter = Scope.active().emitter; BHandle = Scope.active().handle');

    // Active playback has no heartbeat deadline, including prolonged server stalls.
    execute(a, 'Scope.packet(); Scope.advance(20); assert(Scope.active() == Original and not Original.ended and Original.handle == Handle and Emitter.gain == 1, "short server stall stopped music")');
    execute(a, 'Scope.packet()');
    // Only A loses commands; B continues hearing this same station.
    for (let i = 0; i < 30; i++) {
        execute(a, 'Scope.advance(5)');
        execute(b, 'Scope.packet(); Scope.advance(5)');
    }
    execute(a, 'assert(Scope.active() == Original and not Original.ended and Original.handle == Handle and Emitter.gain == 1 and not Emitter.stopped and Scope.client.fading[Scope.radios[1]] == nil, "prolonged heartbeat loss stopped or faded music")');
    execute(b, 'assert(Scope.active().handle == BHandle and not BEmitter.stopped and BEmitter.gain == 1, "another client outage stopped healthy audio")');
    execute(a, 'Scope.packet(nil, 9); Scope.packet(nil, 10, "announce"); assert(Original.phase == "play", "stale packet changed the airing")');
    execute(a, 'Scope.packet(); Scope.advance(0.1); assert(Original.emitter == Emitter and Original.handle == Handle and Original.startedAt == Started, "returning heartbeat restarted an ongoing local file")');

    // Natural completion stays finished until a new airing, even when old packets return.
    execute(a, 'Before = Scope.starts; Emitter.finished = true; Scope.advance(0.1); assert(Original.ended and Emitter.returned); Scope.packet(); Scope.advance(0.1); assert(Scope.starts == Before and Original.handle == nil, "heartbeat replayed a naturally completed file")');
    execute(a, 'Scope.packet(nil, 11); Scope.advance(0.1); assert(Scope.active().handle and Scope.starts == Before + 1, "new music did not start after natural completion")');
    execute(a, 'Scope.packet(nil, 11, "stop"); Scope.advance(2.1); Before = Scope.starts; Scope.packet(nil, 11); Scope.advance(0.1); assert(Scope.active().phase == "stop" and Scope.starts == Before, "explicit stop lost precedence")');
    // A native update powering off a shared device legitimately applies to both clients.
    for (const state of [a, b]) {
        execute(state, 'Scope.radios[1].data.on = false; Scope.advance(0.1); assert(Scope.active() == nil)');
    }
    console.log('PASS: independent clients/radios, local volume and cleanup, station scope, lag-independent playback and natural completion');
} finally {
    lua.lua_close(a);
    lua.lua_close(b);
}
