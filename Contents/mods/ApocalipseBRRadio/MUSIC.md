# Music contract (framework v2.3.0)

## Zombie attraction

Music station registration accepts `attractZombies = true` (optional boolean,
default off). While that station airs a song in `play` or `transition`, loaded
receivers emit repeating AI world sounds once per real second. The server owns
these sounds in multiplayer; single-player emits them locally. Client FMOD
playback never emits duplicate AI sounds.

At full receiver volume the AI sound has radius 100 tiles and strength 60,
matching the vanilla vehicle siren's zombie sound values and update interval.
Both values scale linearly with the receiver volume. This is separate from the
music's audible propagation and speaker attenuation. Placed radios, installed
vehicle radios, and living players' equipped radios are supported. Powered-off,
muted, removed, retuned, blocked, or recorded-media receivers emit nothing;
equipped radios with headphones also emit nothing. Announcements, talk, idle,
end pauses, disabled stations, and stopped songs do not generate this extra noise.
Previously emitted sounds follow the engine's normal lifetime.

```lua
ABRRadio.registerMusicStation({
    id = "my_lure", frequency = 94400,
    name = "My lure station", attractZombies = true,
})
```

The Music Pack supplies `amp_lure` at 94.4 FM alongside `amp_music` at 94.2 FM.
Its lure song IDs use `amp_lure_<hash>` and reuse the same script sound names.
For RCON requests, use the desired station ID and the existing script sound name.

## RCON jukebox

Enable `ApocalipseBrRCONextension` on server and clients to receive requests.
The radio subscribes to `Jukebox.Queue` using the same extension API as the
Furniture and Animals mods. The mod metadata requires `ApocalipseBrRCONextension` on server and clients.
The integration code still handles an unavailable transport gracefully. Its
client relay requires a connected client.

```text
servermsg ##APOCBR_RCON##Jukebox##Queue##unique-request-001##my_music##Alice##mypack_song01##This one is for the survivors!
servermsg ##APOCBR_RCON##Jukebox##Queue##unique-request-002##my_music##Alice##mypack_song01,mypack_song02##Enjoy the playlist!
```

Payload: `stationId##playerName##songId[,songId...]##message`. Each song reference
may be a registered catalog ID or an exact, case-sensitive script sound name
(the song registration's `sound` field), not a title or file path. Catalog IDs
take precedence within the requested station. Sound lookup is scoped to that
station and returns the first matching song in registration order; it never
plays an unregistered sound.
The server resolves the whole batch to catalog IDs before changing any queue.
Chunk sound names are not whole-song identifiers; chunked songs use catalog IDs.

For the script-based Apocalipse Music Pack backend catalog, use station
`amp_music` and the `sound` block name unchanged:

```text
servermsg ##APOCBR_RCON##Jukebox##Queue##unique-request-003##amp_music##Alice##AMP_634C866C151BF661##Enjoy!
```

This resolves `AMP_634C866C151BF661` (Almah - All I Am) to the registered
`amp_song_634c866c151b` entry. The backend does not need to reconstruct catalog
IDs from sound hashes. A sound definition must also have a song registration
on the selected station; the script file alone does not establish eligibility.

Message may be empty (keep the final separator), and
may contain `##`; station and player names cannot contain the separator. Player
name is the supplied attribution, and need not be online. Use a new request ID
for each request; the extension suppresses duplicate relays for one hour.

Requests append atomically to a FIFO queue per enabled station: up to 25 songs
per command and 100 pending songs per station. Unknown songs, songs from another
station, malformed lists, oversized names/messages, control characters, and radio
markup are rejected with a server log. Names are limited to 64 bytes and messages
to 240 bytes. Repeated songs are allowed. Queues are held in memory and reset
on restart. Current music and normal announcer segments finish; requests replace
random song selection until the queue drains. Channel arbitration still applies,
and a request is removed only after music acquires the channel.

Each command produces two radio lines: a compact request/batch announcement with
the next queued song and optional player message, then the number of songs queued
after that song. A batch does not announce every title. Counts are snapshots at
acceptance, excluding the currently airing song. Lines are spaced by at least
three real seconds and sent on music-owned station checks; they wait while text
owns the channel. Playback heartbeats remain independent. The copy uses
`RD_ABR_Jukebox_*_{EN,PTBR}` in both RadioData dictionaries and the server's
broadcast language option.

An empty message queues songs without storing a listener message. Each non-empty
command stores its player attribution and message once, even for a song list.
In addition to the initial request announcement, the station repeats that message
after each of the next five songs, using the translated listener-message
introduction `RD_ABR_Jukebox_Dedication_{EN,PTBR}`. A song already airing when the
command arrives does not count. Ordinary announcer segments do not count either.
All active messages air once per eligible song break, at least three seconds
apart, before the normal announcer or next song; the end pause extends as needed.
Each message expires after five successful repeat broadcasts. Messages remain
station-specific, reset on restart, and are capped at 100 active messages per
station. Failed commands store nothing.

## External announcer message queue

AI agents and other external tools can supply a separate FIFO of radio voice
messages, without a player name or song requests:

```text
servermsg ##APOCBR_RCON##Radio##QueueAnnouncer##unique-voice-001##my_music##Good evening, survivors.##Keep your radios tuned for more music.
```

Payload: `stationId##message1[##message2...]`. Each message is one future
between-song broadcast; sequence order is preserved across commands. Commas and
pipes are literal text; `##` is reserved as the message separator. This hook is
`Radio.QueueAnnouncer`, distinct from `Jukebox.Queue`. The server Lua API is
`ABRRadioMusicServer.queueAnnouncerMessages(stationId, messages)`.

At each song completion, one pending announcer message replaces the station's
normal catalog talk segment. Active player dedications still air first, once per
eligible break under their five-repeat lifecycle. Announcer messages play once,
have no player attribution, and never enter the song, request-announcement, or
dedication queues. The next song waits until the messages and their reading pause
finish; existing music end heartbeats continue. Without queued announcer copy,
the normal catalog talk resumes. Stations without catalog talk can also use this
queue. Commands received after a break begins apply at the next song completion.

Up to 25 messages per command, 100 pending per station, and 480 UTF-8 bytes per
message are accepted. Validation rejects the whole batch if any message is empty,
too long, contains control characters/radio markup, or targets an unknown/disabled
station. Messages are removed only after the radio transmission succeeds and
remain queued if the channel is busy or the radio is unavailable. Queues reset
on restart. Copy is broadcast verbatim in the language supplied by the agent;
it is dynamic content, not a built-in translation label. No audio/TTS is generated
by this hook.

ApocalipseBRRadio owns the shared music registry/protocol, real-time server
scheduler, client audio, and channel arbitration. Content packs supply
stations, songs, timed talk, sound definitions, and audio assets. The framework
loads without any music pack and does not register a music station on its own.

```lua
require "ApocalipseBRRadio/ABRRadioMusic"

ABRRadio.registerMusicStation({
    id = "my_music", frequency = 94200,
    name = { EN = "My music station", PTBR = "Minha radio musical" },
    talkChance = 100,
})

ABRRadio.registerSong({
    id = "mypack_song01", station = "my_music",
    title = "Title", artist = "Artist", duration = 120,
    -- Supply these sound scripts and assets in the content pack.
    sound = "MySong",
})

ABRRadio.registerMusicTalk({
    id = "mypack_ident", station = "my_music", duration = 6,
    lines = { { at = 0, text = "You are listening to My music station." } },
})
```

IDs are stable, unique catalog codes (1-24 ASCII alphanumeric/underscore/hyphen
characters), not array indices. Duration and timestamps use real seconds.
Default weight is 10; song repetition is avoided when more than one is available.
Stations with talk entries always play one announcer segment between songs;
`talkChance` remains accepted for older packs but no longer skips those transitions.
Song lyrics are not supported. Legacy song `lyrics`, `lyricDuration`, and `lines`
fields are discarded during registration. Timed talk lines are sent by the
authority as ordinary radio text on the first station check within their active
timestamp window. Windows shorter than a complete scan can be skipped. Talk uses
until-next-line timing by default, with optional `untilTime`. Labels and captions
use the framework's configured EN/PTBR language.

Late listeners start the current song from its beginning on their first playback
heartbeat. Ordinary files cannot seek through the exposed API. Only the server
tracks the registered song duration to end the broadcast and schedule the next
segment. Clients receive no elapsed or remaining time and do not estimate a song
deadline. They follow native audio completion, local receiver eligibility, and
the station's start/end metadata. Missing heartbeats never expire active audio.

Whole-file `sound = "MySound"` is preferred. Existing chunk-only catalogs remain
supported: the receiver starts the first chunk and advances using local playback
time. When both `sound` and `chunks` are supplied, the whole-file sound wins.
This is local file playback, not streamed audio or exact musical synchronization.

The authority waits 50 OnTick callbacks, then visits one music station per tick
in registration order. During normal song playback it waits another 50 ticks
after the last station. Announcements, post-song pauses, and timed announcer
segments skip that wait so transitions and short text windows are checked each
scan. It still processes at most one station per tick. At the
target 10 ticks/second, a complete cycle takes `(50 + station count) / 10` real
seconds. Station updates use the elapsed `getTimestampMs()` time since that
station's previous check, so server stalls are included. Waiting callbacks do
not read the clock or scan the station table. Song selection still scales with
the selected station's catalog size when a new segment is chosen.

Before each song, the authority transmits `[img=music] Title - Artist`, then waits
at least three real seconds before sending the playback heartbeat on its next
station check. Heartbeats are due after five seconds and sent during those
checks as silent `ApocalipseBRRadio/MusicState` server commands. Only the initial
announcement and timed announcer lines use native radio text; control packets
never trigger vanilla chatter/static effects. Clients cache the newest station
state and apply it to tuned, audible receivers during bounded device discovery.
Clients do not report listeners or acknowledge heartbeats.

On its first check at or after the registered song duration, the authority sends
an end heartbeat. Clients
lower remaining audio to 50% of the current radio volume over 100 client frames,
then hold that tail under announcer speech. A `transition` phase begins near the
server song deadline; `end` preserves any remaining tail, including a late
listener's unfinished song. When the next track starts at 50% gain, its volume
rises to the radio setting over 50 frames while the tail fades to zero over the
same 50 frames. Repeated end heartbeats cannot restart the song. The channel stays owned
for a random, inclusive 0-5 real seconds after the song ends. A zero-second
pause releases ownership in the completion check; positive pauses release it at
the first check after their deadline. The same check attempts the next segment,
with queued radio text retaining priority. When announcer content exists, its
segment starts immediately after song completion without a random pause. Its
last line gets up to two seconds before the next song announcement, whose wait
is shortened to 0.5 seconds. Only then are
queued text, timed talk, and the next song eligible. Every registered music
station uses this lifecycle independently.

## Receiver audio

Each client owns one local music emitter per receiving radio, not per listener.
The client uses `playSoundImpl(sound, false, nil)`; `playSound` would send a
native sound packet and duplicate playback on other clients that already render
the same broadcast. Server heartbeats identify the active transmission and its
lifecycle; each receiver starts its own audio at zero. Repeated callbacks for
the same receiver do not restart audio.

The server sends station lifecycle metadata only, not listener volume or
receiver-specific stop commands. Client proximity and hearing checks use local
players (`getSpecificPlayer`), not the server's connected-player list. Moving
away or stopping a different receiver on one client cannot
stop another client's emitter. Native device power, tuning, and slider settings
belong to the physical radio and can be synchronized by the game: turning off
the same shared world/vehicle radio affects everyone hearing that device.
Distance attenuation and hardware loudness are still calculated on each client.

Radio music uses non-spatial (2D) playback so cars, placed radios, and portable
speakers use the same volume curve without game directional panning. Existing
audio files retain their authored stereo channels; this does not downmix assets.
Playback activates and stays eligible within 200 yards (182.88 tiles,
approximating one tile as one metre). Audible propagation is a separate maximum
of 100 yards at full radio volume: 50% reaches 50 yards and 25% reaches 25 yards.
The full-gain reference distance scales from 10 tiles at full volume. Outside
that reference distance, the clamped linear distance factor is squared for a
steeper falloff. A powered, tuned receiver between its audible radius and the
200-yard lifetime cutoff starts/continues at zero gain, so approaching the radio
reveals the same track without restarting. Lower volumes shrink the attenuation
zone and make the gain drop more rapidly per tile. Headphones bypass propagation
attenuation; their gain still follows radio volume. Vertical distance
retains its three-tile weight per floor. For multiple local players, the nearest
eligible listener determines gain. Headphones remain owner-only at full distance
gain. Final gain is radio volume times transition gain times distance gain; FMOD
spatial attenuation/occlusion is disabled to avoid applying a second curve.

The Music Pack generator uses `is3D = false`, `distanceMin = 10`, and
`distanceMax = 128`; its distance fields are reference metadata for 2D playback.
The shared `LISTEN_RANGE` controls the fixed 200-yard activation/lifetime
cutoff. `PROPAGATION_RANGE`, `FULL_VOLUME_RANGE`, and `DISTANCE_FALLOFF_POWER`
control audible gain: propagation uses `PROPAGATION_RANGE * radioVolume`.
Discovery checks the full registered receiver list including
one-way radios. Radios must be loaded on the client to be discovered.

Power off, mute, retuning, recorded-media playback, blocked reception,
unequipping/transferring a portable radio, picking up/removing a placed radio,
uninstalling/removing a vehicle radio stop and release the owned emitter
immediately. Song end/replacement preserves the outgoing tail for the next track's crossfade.
Explicit server stop fades to zero over two seconds. Heartbeat silence never
fades, stops, or restarts a file already playing, including an outgoing song
held under announcer speech. Proximity and volume are evaluated on every client
tick independently of packet arrival. The client checks the owned handle with
`emitter:isPlaying(handle)` and releases it when the file naturally finishes.
Native FMOD ticking removes completed handles; pending-start handles also count
as playing. Whole-file completion retains the airing sequence so another packet
for that same song cannot replay it. Legacy chunk-only songs continue their
remaining chunks on the local playback clock, then finish after the last chunk.
End heartbeats repeat during the pause
so a lost end packet can be recovered on the next heartbeat. A replacement song
starts at half gain while outgoing audio crossfades to zero. Local time is
used only for chunk sequencing, fades, retries, and discovery snapshot freshness.

`getHeartbeatTimeout()` now limits only cached discovery snapshots: three scans
at the target tick rate with an eight-second minimum (15.3 seconds for one
station). A newly loaded/tuned receiver waits for fresh state when that snapshot
is stale; existing playback remains uninterrupted. If the server stalls or
disconnects, the current file can finish naturally and the client waits for new
station state. It does not replay the file to fill the gap.

Playback handles must be positive: a zero or negative result releases the failed
emitter and retries at most once every two seconds while the broadcast remains
active. One diagnostic is printed per receiver/transmission. Native static/VOIP
emitters remain owned by the game.

## Channel ownership

The listener controller forces microphone mute on local inventory radios and
nearby placed, dropped, and vehicle radios tuned to any registered music
frequency. This applies to admins too, during silence and with speaker volume
zero or power off. Discovery visits at most eight registered devices globally,
eight inventory items and four nearby grid squares per local player per tick;
all dropped objects on each visited square are checked. A complete nearby
square scan takes 41 ticks. Inventory and registered-device discovery latency
grows with their list sizes. A received music heartbeat also protects its device
immediately. Once discovered, forced mute is checked every tick independently
of playback; the previous microphone setting is restored on retuning or when
the device leaves the local inventory/neighbourhood.

Do not set `NoTransmit` for this purpose: vanilla also rejects received
broadcasts for these devices, preventing the music heartbeat protocol. The
microphone guard uses `DeviceData.setMicIsMuted` and is a client restriction,
not validation of malicious clients on the server. Original microphone settings
are retained in memory for the current session; saving while forcibly muted
can preserve that muted setting across reloads.

Audio emitters still tick each frame for smooth playback and fades. The
controller reuses the audibility position lookup and only changes FMOD volume
and headphone/spatial mode when their values change. Empty receiver tables naturally skip the audio loops. Kahlua has no `next()`
global; use `pairs()` for iteration.

`ABRRadioServer.tryAcquireChannel(channelId, owner)` acquires an enabled idle
channel only when no immediate message is waiting and no eligible scheduled text
is due. `releaseChannel(channelId, owner)` releases only the matching owner.
`isChannelBusy(channelId)` reports ownership or an active text transmission.
These calls are server/SP contracts; clients only render received state.

The music scheduler owns a channel through the song announcement, complete song
duration, and 0-5 second post-song pause. Timed talk owns it for its duration.
During ownership, the normal scheduler cannot send/advance text on that channel,
and `triggerImmediate` messages remain queued. Deferred messages retain all their
lines and drain in order after release, before music resumes. Scheduled-text
cooldowns can become due during music and receive a turn at a segment boundary.
Music cannot start over an ongoing text transmission. Other frequencies remain
independent. Existing immediate text can still interrupt ordinary text when it
has not been held behind a music segment; held messages wait for text completion.

Arbitration governs the framework's scheduling APIs, not direct native or
third-party `ZomboidRadio.SendTransmission` calls. Choose a frequency that does
not collide with a vanilla station or another mod's broadcaster.

## Runtime files and compatibility

- Shared: `common/media/lua/shared/ApocalipseBRRadio/ABRRadioMusic.lua`.
- Authority: `common/media/lua/server/ApocalipseBRRadio/ABRRadioMusicServer.lua`.
- Listener: `common/media/lua/client/ApocalipseBRRadio/ABRRadioMusicClient.lua`.
- Ownership and text scheduling: `ABRRadioServer.lua`.

Server commands carry `id`, `sequence`, and `phase` (`announce`, `play`,
`transition`, `end`, or `stop`). Sequence and phase ordering reject delayed packets that would revive an
ended transmission. There are no elapsed-time, remaining-time, duration,
audio-path, or lyric fields in the metadata. Only the server sends song title/artist text, once per airing at announcement.
Clients do not synthesize captions on discovery or recovery. Lifecycle heartbeats contain no visible
text. Timed talk is sent separately as ordinary radio text. Playback is filtered
by tuning, power, volume, position, and listener hearing. The legacy
`AMP2|content_id|sequence|phase` decoder remains for old radio events; new servers
send control commands. Deploy the updated framework to server and clients
together. AMP1 is no longer accepted.

`ApocalipseMusic` remains an alias of `ABRRadio.music` for existing generated
catalog modules. New code should use the public `ABRRadio.register*` methods.
Install the updated radio framework on server and clients, and rebuild older
music-pack installations to remove their former `AMPClient`/`AMPServer` runtime;
two runtimes must not run together.

Framework behavioral checks live in `tests/music_spec.lua`. From the Workshop
repository root run:

```sh
npm exec --yes --package=fengari-node-cli -- fengari tests/run.lua
```

The older music-pack test suite targets the former chunk-boundary joining
contract. In-game Kahlua/FMOD and multiplayer playback still need a smoke test.

Server diagnostics use `[ABRRadio Music Server]`. Startup logs distinguish the
controller loading from `OnLoadRadioScripts` readiness and list each station's
name, ID, frequency, song/talk counts, and enabled state. Runtime logs print on
phase changes and every 60 real seconds per station, including content ID,
caption, and elapsed/duration. Waiting states identify an empty catalog, channel
ownership contention, or a disabled station. Completion is logged separately.
These logs report the authority's scheduling state; client reception and local
audio playback still require checking a listening device.

Client diagnostics use `[ABRRadio Music Client] Received` for control phase
changes and `Audio started` when FMOD returns a positive handle. Missing catalog
entries and failed sound starts identify the content/sound ID. These diagnostics
do not prove the local audio is audible; receiver volume and proximity still apply.

The 100/50-frame ramps advance once per client OnTick, so wall-clock duration
varies with client FPS. Playback is not kept running when a radio is powered off
or muted, and the game soundtrack volume is not modified. Only an outgoing
transition tail and its incoming song temporarily overlap per receiver.

MusicState heartbeats are sent to every connected client through the mod's
server-command channel, without a player-to-radio network relevance radius.
Activation still requires a registered receiver loaded on that client and a
listener within the 182.88-tile playback cutoff. The non-spatial emitter uses a separate Lua attenuation curve out to at most
100 yards, while keeping playback alive out to 200 yards.
The Music Pack records 10/128-tile clip distances for consistency. Vanilla announcer text uses the radio's own text/signal range and
is not needed to trigger music playback. Client chunk loading may limit which world receivers can be discovered
before the 200-yard cutoff.

While receiver state is retained, duplicate heartbeats never reset the playback
handle, local start time, or fade-in progress. Missing packets leave those values
unchanged; returning packets for the same airing do not restart playback, even
after its file has naturally completed. Stale sequence/phase packets cannot
revive playback, and an explicit stop/end is never undone by an old play packet.
A new server sequence can start normally. Receiver
removal, retuning, power-off, mute, and leaving range still release state, so
later listening starts at the beginning as before. Replaced DeviceData settles
into one new receiver state. Client logs include airing sequence and receiver
identity; release reasons distinguish local eligibility loss from natural file
completion. The client logs native completion as `Finished locally`.

Speaker profiles use `DeviceData.getBaseVolumeRange()` as the native hardware
rating, before slider and location effects. Vehicle radios inherit this rating
from the installed inventory item. A rating of 15 is the full-strength reference;
ratings above 15 are capped. Portable speakers receive an additional 0.6 scale;
vehicle and stationary scales default to 1. The portable/two-way flags identify
hand radios versus walkie-talkies, while `getVehicle` identifies vehicle parts.
RF transmit range is not used as a speaker metric.

`strength = clamp(baseVolumeRange / 15, 0, 1) * categoryScale`, capped at 1.
Audible range is `100 yards * radioVolume * strength`, inner reference range is
`10 tiles * radioVolume * strength`, and final gain is
`radioVolume * strength * distanceFalloff^2 * transitionGain`. Native rating zero
makes speakers silent without dividing by zero. Headphones bypass speaker and
propagation modifiers. Playback activation/lifetime remains 200 yards. Defaults
are configurable through `SPEAKER_REFERENCE_RANGE`, `PORTABLE_SPEAKER_SCALE`,
`VEHICLE_SPEAKER_SCALE`, and `STATIONARY_SPEAKER_SCALE` in the shared module.
Audio-start logs include device category and computed speaker strength.

For an effective nominal propagation radius above 60 yards, attenuation progress
is multiplied by 1.2 before the existing squared falloff. Every speaker profile
also receives a universal 1.3 multiplier, giving a combined 1.56 rate above
60 yards and a 1.3 rate at or below 60 yards. The nominal radius
and inner reference distance are not expanded to compensate, so silence occurs
sooner: `inner + (nominalRadius - inner) / combinedRate`. A full-strength 100-yard
profile reaches zero near 68 yards. Smaller profiles also become silent sooner
through the universal multiplier; ranges are not expanded to compensate. The threshold is evaluated after radio volume and hardware modifiers,
with a small floating-point tolerance at exactly 60 yards. Playback activation
and lifetime remain 200 yards. Transition gain is a separate multiplier: the
100-frame reduction to 50% halves the already hardware/distance-adjusted output
without changing the audible-radius calculation. Tuning constants are
`FASTER_FALLOFF_THRESHOLD`, `LONG_RANGE_FALLOFF_RATE`, and `GLOBAL_FALLOFF_RATE`.
