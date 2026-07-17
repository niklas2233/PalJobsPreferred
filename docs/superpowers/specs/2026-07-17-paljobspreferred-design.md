# PalJobsPreferred — Design

## Overview

A replacement for the `PalPriority` + `PalPriorityUI` UE4SS Lua mod pair for
Palworld. Same core idea — per-pal, per-work-type priority overrides driven by
in-game work-type toggles — rebuilt to actually work against a real dedicated
server, with a live client-side display and no external tooling required.

## Background

The original mods only fully worked in singleplayer/listen-server, where
client and server share a process and filesystem. Against a real dedicated
server:

- The client's live number overlay read a local file that never reflected the
  server's real state (no shared filesystem between separate machines).
- Toggle-click attestation (`Request_Server_int32`, an existing Palworld RPC
  repurposed as a tagged client→server message channel) silently broke in any
  world with more than one base, because the client resolved its own base
  component via `FindFirstOf("PalNetworkBaseCampComponent")` — grabbing
  whichever instance the engine happened to enumerate first, not necessarily
  one the calling client has network authority over. Unreal drops a server RPC
  called on a component the caller doesn't own, silently, with no error on
  either side.
- The F9 debug roster dump was dev-only-gated (`DEBUG=false`) and, even
  enabled, unreachable on a headless dedicated server (no OS window to receive
  a keypress).

## Goals

1. Correct multiplayer support: priority toggling works against a real
   dedicated server, for any number of players/bases.
2. Live, accurate client-side display of current priority state —
   self-contained. Drop the mod folders in; it works. No sidecar process, no
   external viewer, nothing to run separately.
3. More responsive interaction: set an exact value directly instead of only
   step-cycling one increment at a time; push updates on change instead of
   polling.
4. Graceful vanilla fallback: a player without the client mod installed still
   sees normal on/off checkboxes and gets sensible default behavior.

## Non-goals

- No external sidecar server, no companion desktop app, no network bridge
  outside the game's own client-server connection.
- Only verified against this Wine-hosted dedicated server setup; not
  specifically targeting native-Linux Palworld server builds.

## Architecture

Two Lua mods, same split as the original:

- **PalJobsPreferred** (server-side, `NativeMods`) — ported from
  `PalPriority`'s hook/cycling/config logic.
- **PalJobsPreferredUI** (client-side) — ported from `PalPriorityUI`'s
  cell-injection/render logic.

UE4SS's Lua API has no sockets/HTTP — all communication piggybacks on
existing Palworld network RPCs:

- **Client → Server**: `PalNetworkBaseCampComponent:Request_Server_int32`
  (already proven to work over a real network once the component-resolution
  bug below is fixed). Message vocabulary (via a leading `FName` tag):
  - `PrioMod_Ping` — client announces itself as modded (unchanged from
    original).
  - `PrioMod_Dir` — left-click = +1, right-click = -1, one step at a time
    (unchanged interaction, now correctly routed).
  - `PrioMod_SetPrio` — **new**: set an exact 0–10 value for a specific
    work type on a specific pal in one call, for faster access to values
    that would otherwise take several clicks to cycle to.
- **Server → Client**: a second existing RPC/replicated channel, **to be
  identified during the research phase** (see below), used to push current
  priority state to the owning client(s) on every change — replacing the
  old local-file-poll display entirely.

## Component-resolution fix (critical correctness fix)

The client must resolve *its own* `PalNetworkBaseCampComponent`, not
`FindFirstOf`'s arbitrary first match. Resolution goes through the local
player controller/pawn's ownership chain instead of a blind global lookup.
Exact call sequence finalized during implementation, validated against a
real multi-player, multi-base world (the test world has 2 players, 3 bases).

## Config format

`priorities.lua`, same shape as today, `prio` values now range **0–10**
(was 0–5) to give finer granularity across the game's 12 work types.

**Storage format decision**: stays a Lua table (`return { pals = { ... } }`),
parsed via `load()`, not JSON. Rationale: UE4SS's Lua sandbox has no built-in
JSON library, so a Lua table is a zero-dependency format — `load()` gives a
free parser with no vendored file needed. It also preserves the original's
hand-editable, comment-friendly format (the roster/dump tooling generates
ready-to-paste commented entries). The main downside of a code-as-config
format — executing arbitrary content — is a non-issue here specifically
because in this design the file is **purely server-side persistence**: the
client no longer reads it directly at all (it receives pushed state over the
network channel instead), so nothing cross-machine ever depends on parsing
this file's contents.

## Fallback behavior for unmodded clients (explicit, preserved from original)

- Unconfigured pal touched by a vanilla client: fully ignored, pal stays
  vanilla.
- Configured pal touched by a vanilla client: released back to plain
  vanilla on/off (its config entry is cleared) — no confusing interaction
  for a player without the client mod.
- Vanilla on/off maps to priority **5** (on) / **0** (off) on the new scale
  — a vanilla client can only ever send true/false, so 5 (midpoint) is the
  sensible single default for "this matters, but isn't specially
  prioritized."

## Responsiveness improvements

- `PrioMod_SetPrio` reaches any value in one interaction instead of cycling
  through every intermediate step.
- Event-driven state push (once the server→client channel exists) replaces
  the client's 500ms poll loop; the server's periodic reconciliation only
  handles background drift-correction, not the main update path, which is
  hook-triggered and immediate.

## Research phase (server → client channel)

Performed on a **disposable, throwaway dedicated server container** (same
image, scratch save) — never the live server 2 people are actively playing
on. UE4SS's SDK-header-dump feature carries a real crash/memory-cost
warning in its own config, so this happens somewhere a crash costs nothing.

Steps: generate a full SDK header dump on the throwaway server, inspect
`PalNetworkBaseCampComponent` and related classes for an existing
client-bound RPC or replicated property suitable to repurpose the same way
`Request_Server_int32` already is, validate it actually round-trips data
correctly, then port the finding into the real mod.

## Fallback if no server→client channel is found

Toggling correctness does not depend on this research succeeding — that
part is already solved via the component-resolution fix. If no reverse
channel is found, the live overlay degrades gracefully to "accurate as of
when the work screen was opened" rather than continuously live. Never worse
than today's baseline (which doesn't work on a dedicated server at all);
never blocks the core toggle functionality shipping.

## Testing

- Non-networked logic (priority cycling math, config load/save, vanilla
  fallback defaulting) — pure Lua, testable in isolation without a live
  game.
- Networked pieces — verified live against the disposable research server
  first, then against the real dedicated server using the actual 2-player,
  3-base world as the multiplayer correctness test case.
