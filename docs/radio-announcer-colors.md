# Colored announcer messages over RCON

`Radio.QueueAnnouncerV2` supplies individual whole-line colors without embedding
markup in the spoken text. The existing `QueueAnnouncer` subscriber remains
available and keeps its previous parsing and station-color behavior.

```text
servermsg "##APOCBR_RCON##Radio##QueueAnnouncerV2##unique-color-001##amp_music##1.5|255,153,0|A warning.##4|default|Back to the music."
```

The outer RCON extension forwards the payload unchanged and retains its relay
authentication and module/command/request-ID deduplication. The payload is
`stationId##entry1[##entry2...]`; each V2 entry requires
`adjustmentSeconds|R,G,B|text` or `adjustmentSeconds|default|text`.

- RGB components are integers in 0–255, without spaces. `default` inherits the
  station color. Only the first two pipes are structural; later pipes and commas
  belong to the text. `##` separates messages and cannot occur in message text.
- `ABRRadioJukeboxRCON.lua` parses V2 and normalizes RGB by dividing by 255.
  Invalid fields reject the batch before calling the queue. It subscribes to both
  versions independently; V2 never falls back to interpreting malformed fields as text.
- `ABRRadioMusicServer.queueAnnouncerMessages` validates normalized colors, copies
  them into the queue, and appends only after all entries pass. Direct Lua callers
  use `{ text, intervalAdjustment, color = { r, g, b } }`, with RGB in 0–1.
- `broadcastAnnouncer` passes the queued message color, or station color when absent,
  directly into `ZomboidRadio:SendTransmission`. It retains FIFO, player dedication
  priority, song-break scheduling, 25-message batches and 100-message station queues.
- Timing remains `max(0.5, 3 + adjustment)` real seconds after successful delivery,
  including the final line. Initial delay and music resumption remain unchanged.

The manager's `radio-programme-v8` prompt and strict generation schema require
each JSON message to include `color`, either null or an object containing exactly
integer `r`, `g`, and `b` in 0–255. It prefers null for ordinary conversation,
orange for warnings, light red for evidenced immediate danger, and light green
for achievements. The manager validates colors, retains them when adding speaker
labels/persisting/replaying plans, and serializes V2 entries. Older saved plans
without a color inherit the station color. No new mod sandbox options or database
migrations are required. Install the updated mod before the manager emits V2.

Whole-line RGB colors placed, equipped and vehicle radio bubbles. Weather/range
interference can turn text gray. Vanilla radio chat logs do not retain these RGB
values; this change does not modify that UI.

`tests/jukebox_spec.lua`, run with `npm test`, checks both subscribers, exact RGB
forwarding, default/legacy station colors, copied color data, literal pipes,
invalid/capacity batch rejection and pause/music-resumption behavior using mocked
native APIs. Manager tests use isolated provider transport, repositories and
temporary databases. Visual multiplayer reception still needs an in-game smoke
test; ordinary verification sends no live RCON commands or notifications.
