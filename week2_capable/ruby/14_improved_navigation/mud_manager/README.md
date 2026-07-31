# MudManager — CircleMUD sessions, command primitives, and an MCP daemon

One gem, one binary. `MudManager` has two layers:

- **The domain** (`MudManager::Session` + `MudManager::Primitives`): a
  long-lived telnet connection with background buffering, IAC stripping, and
  the CircleMUD login/reconnect dance, plus a stateless library of
  enum-validated command builders.
- **The daemon** (`MudManager::Mcp::*`, the `mud-manager` binary): a single
  long-lived process that owns a `Session` and exposes it to agents in *any*
  language over stdio, so nobody has to reimplement telnet, threading, or the
  login dance in Java, Python, Rust, or Go.

This implements [`docs/plans/mud_manager/generic_interfacing.md`](../../docs/plans/mud_manager/generic_interfacing.md)
and [`docs/plans/mud_manager/single_gem.md`](../../docs/plans/mud_manager/single_gem.md)
(the plan that folded what used to be a separate `mud_manager_mcp` gem into
this one).

## Two protocols, one daemon

| Mode | Command | For |
|------|---------|-----|
| **MCP** (JSON-RPC 2.0 + tool discovery) | `mud-manager --mcp` | The blessed path. Any agent SDK that speaks MCP gets typed MUD tools with zero protocol code. |
| **Raw JSON-line** | `mud-manager --stdio-json` | The low-level teaching artifact / escape hatch — one JSON object per line, trivial to implement a client for by hand. |

Both are driven by the **same** `SessionPool` + `Dispatcher` and expose the
**same** tools, generated from one canonical Ruby source (`ToolSpec`).

## Running the MCP server

`--mcp` is the default mode, so bare `mud-manager` and `mud-manager --mcp` are
the same thing. The server speaks JSON-RPC over **stdio** — it has no port and
you don't start it yourself in a terminal; your MCP client spawns it as a
subprocess and keeps it alive for the session. Credentials come from the
environment (see below), never from tool args.

```jsonc
// Any MCP client's server config — e.g. .mcp.json, claude_desktop_config.json
{
  "mcpServers": {
    "mud": {
      "command": "mud-manager",
      "args": ["--mcp"],
      "env": {
        "MUD_HOST": "localhost",
        "MUD_PORT": "4000",
        "MUD_NAME": "YourCharacterName",
        "MUD_PASSWORD": "yourpassword"
      }
    }
  }
}
```

For Claude Code specifically:

```sh
claude mcp add mud --env MUD_NAME=YourCharacterName --env MUD_PASSWORD=yourpassword -- mud-manager --mcp
```

If you haven't `gem install`ed yet, swap `mud-manager` for
`ruby /abs/path/to/mud_manager/bin/mud-manager`.

The daemon doesn't touch the MUD at startup — it connects and logs in lazily on
the first gameplay tool call, so a misconfigured `MUD_*` surfaces as a tool
error, not a failed launch. To sanity-check the process without a client, run
`mud-manager --list-tools` (no MUD needed) or pipe JSON-RPC in by hand as shown
under [Quick start](#quick-start).

```
agent (any lang) ──stdio──> mud-manager ──TCP/telnet──> CircleMUD
                              │
                              ├─ Mcp::Server / Mcp::JsonLineServer  (transport)
                              ├─ Mcp::Dispatcher                   (tool name+args → text)
                              ├─ Mcp::SessionPool                  (the one stateful thing)
                              │    └─ Session + Primitives         (the domain)
                              └─ Mcp::ToolSpec  ──generates──> primitives.json
```

## Tools

The daemon exposes exactly the gameplay surface `Boukensha::Tools::Mud`
registered back when boukensha had in-process tools (`look`, `move`,
`attack`, `cast_spell`, `shop`, …, `send_raw`), **plus** two daemon additions:

- `poll` — return unprompted output that arrived while idle (combat ticks, other
  players) without sending anything.
- `mud_status` — is the session connected?

…**plus** the three navigation tools the map adds (see below).

Connection tools (`connect`/`login`) are **not** exposed to the LLM. Session
lifecycle is a framework concern (plan §5): the daemon connects and logs in
lazily on the first gameplay call, using credentials from env/config, and
transparently reconnects on a dropped socket.

### Credentials (never from tool args)

Resolution order: explicit → env → `~/.boukensha/settings.yaml` → defaults.

```
MUD_HOST   (default localhost)     MUD_NAME / MUD_USER
MUD_PORT   (default 4000)          MUD_PASSWORD
```

## The map

The daemon draws its own map as it plays. Implements
`docs/plans/week2/14_improved_navigation.md`.

**Why.** A measured tbaMUD session spent 1,698,189 input tokens on 50 moves —
roughly 34,000 input tokens per step through a doorway, almost none of it the
model thinking. It was the same history and the same 40 tool schemas re-sent on
every call while the agent walked in circles, because it had no world model.

**Three tools, and the map itself never enters the model's context.** Dropping a
map document into every call would rebuild that ratio in a new costume. The
agent asks a question and gets a sentence back:

| tool | what it does |
|---|---|
| `map_where` | `look` plus `exits`, matched against the stored map: where you are, which exits lead to rooms you know, which are still untried, and what the game says is behind them |
| `map_goto` | shortest route to a named room, **walked in a single call**, routing around doors and obstacles it has learned |
| `map_explore` | walk to the nearest exit never tried, and take it |

### `look` gives directions. `exits` gives directions and destinations.

Two different observations, and the second is the cheaper one:

```
look   ->  [ Exits: n e s w d ]

exits  ->  north - By The Temple Altar
           east  - The Midgaard Donation Room
           south - The Temple Square
           west  - The Reading Room
           down  - The Temple Square
```

`look` says five exits exist. `exits` names the room behind each, without
moving. So one round trip labels up to six edges that would otherwise cost a
walk each to discover, and `map_goto "donation room"` can route to a room
nobody has ever stood in.

A listed name labels the **edge**, never a room. The key is still
`(title, description)` hashed, because a title is not unique: three rooms are
called "Main Street", and in the listing above `south` and `down` both claim
"The Temple Square". Walking the edge is the observation that settles it, and a
disagreement between what was listed and what was found is recorded as a
contradiction rather than quietly overwritten.

The listing is asked for once per room. Re-asking an unchanged room repeats what
it already said, and a direction the listing omits stays unnamed: we have never
observed what `exits` does with a shut door, so nothing is concluded from its
absence.

**How it is built.** Every gameplay result passes through `Mcp::Dispatcher`,
which has the tool name, the arguments and the response together, and folds
them into the map with one function: `(world, tool, args, result) -> world`.

- **Parsing anchors on ANSI colour, which is structure rather than noise.** The
  title is the first `ESC[0;33m` line, the exits are the `ESC[0;36m` line, the
  description is everything between, mobs and objects are everything after.
  Mobs are yellow too, so stripping colour first throws away the only reliable
  way to tell one from a room title. Shut doors arrive pre-announced as red
  parenthesised directions — `[ Exits: n s (w) ]` — so an edge is known to be
  doored before it is ever walked.
- **Identity is `(title, description)`, hashed.** "Main Street" covers three
  physically distinct rooms, so the title alone is not a key. Minting a node on
  every arrival makes two routes to one room into a phantom wing of the
  building; conditional minting is what keeps them one node.
- **Never invent the reverse edge.** A north from A to B does not imply a south
  from B to A. It is recorded when it is walked, and not before.
- **Announced-but-unwalked exits are recorded as edges to nowhere.** That is the
  frontier, and it is what turns "find X" from wandering into a search.
- **The map is checked against itself.** Same room + same direction must always
  lead to the same node; a revisit must observe the exit set already recorded;
  a room announcing four exits cannot grow a fifth; a walked exit must arrive
  where the listing said it would. A violation is a wrong merge surfacing, so
  merges are reversible: every edge records the observation sequence that
  established it, and `World#split` takes a node back apart.
- **Conflicting observations are never averaged.** When a revisit announces a
  different exit set, the two sets are not unioned. A union is a room that was
  never observed, and it buries the contradiction it was just handed. The most
  recent observation is kept, the room is flagged as a suspected wrong merge of
  two same-key rooms, and the now-stale edges show up in the degree audit.
- **No world file is ever read**, in the code, the fixtures or the tests. The
  agent works it out by walking.

**It persists.** `~/.boukensha/maps/<host>_<port>.json` (override with
`MUD_MAP_DIR`), written as you play and loaded at boot, including the room you
were last standing in — so tomorrow's session routes immediately instead of
re-exploring. Play for fifty hours, map the city, come back, and it knows the
way to the bakery.

**Search takes state as a parameter.** The graph is not mutated when the
character picks up a key; edges carry preconditions evaluated against a state
passed in. That is what makes counterfactual queries possible ("could I reach
the crypt if I held the brass key?"), and it is why the search is Dijkstra
rather than BFS: a plain exit costs 1, a beatable mob costs more, an edge that
needs a boat you do not have is infinite. Uniform-cost search cannot express
"go the long way around the ogre".

### Replaying a recorded session

The updater is a pure function, so it can be fed a recorded session instead of a
live one — the same function in a loop, with no MUD running and no tokens spent:

```sh
mud-map-replay ~/.boukensha/sessions/*.jsonl --render graph_paper.md
```

It prints room and edge counts and any invariant violations. Session logs are a
debug trace, **not** an input to the real map — this is for hardening the parser
and the merge rule offline. The graph paper it renders is likewise write-only:
a rendered map cannot disagree with the map, but a second file you both write
and read will drift.

## primitives.json — Ruby is canonical

`ToolSpec` pulls every enum **live** from `MudManager::Primitives` constants, so
`primitives.json` can never drift from the gem. Regenerate it with:

```sh
mud-manager --dump-spec       # or: rake spec
```

Other language tracks generate local typed builders from this one file.

## Build and install the gem

From this directory:

```sh
gem build mud_manager.gemspec
gem install ./mud_manager-0.3.0.gem
```

That's the whole distribution story: one `gem install`, and `mud-manager` is
on your PATH. No second gem to keep version-locked, and no Ruby toolchain
needed beyond running `gem install` itself.

```sh
mud-manager --list-tools
```

### Uninstall

```sh
gem uninstall mud_manager
```

## Quick start

```sh
# See the tool schemas (no MUD needed):
ruby bin/mud-manager --list-tools

# Talk MCP by hand:
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ruby bin/mud-manager --mcp
```

## Using the domain directly

`MudManager::Session` and `MudManager::Primitives` are also usable on their
own, without the daemon — this is what the daemon's `SessionPool` does
internally.

```sh
MUD_NAME=YourCharacterName MUD_PASSWORD=yourpassword ruby examples/live_session_test.rb
```

```ruby
require "mud_manager"

session = MudManager::Session.new(host: "localhost", port: 4000)
session.open
session.login("YourCharacterName", "yourpassword")

session.send_command(MudManager::Primitives.look)
puts session.read_until_quiet

session.close
```

## Using it from boukensha (the Ruby "MCP path")

`examples/boukensha_mcp_demo.rb` spawns `mud-manager --mcp`, discovers its
tools, and registers them into a `Boukensha.run` block via boukensha's own
generic MCP layer (`Boukensha::Tools::Mcp`) — the identical flow the
Python/Go/Rust/Java tracks follow with their own SDKs. This package ships no
boukensha-specific code; to boukensha, `mud-manager` is just an MCP server.
Run it self-contained (built-in fake MUD, no API key):

```sh
ruby examples/boukensha_mcp_demo.rb --dry
```

For a full agent run, set `ANTHROPIC_API_KEY` + `MUD_*` and drop `--dry`.

## Testing offline

`MudManager::FakeMud` is an in-process CircleMUD stand-in (login dance +
command echo, `push` for async output) so clients — in any language pointed at
`127.0.0.1:fake.port` — can be validated without a live server.

```sh
rake test
```

## Packaging

This gem ships the domain (`Session`, `Primitives`) and the daemon
(`Mcp::*`, the `mud-manager` binary) together, dependency-free: a Rust/Go/
Python bootcamper runs one `gem install mud_manager` and gets the
`mud-manager` binary on their PATH — no Ruby knowledge needed to *use* it.
This used to be two gems (`mud_manager` + `mud_manager_mcp`, the latter
depending on the former); they were folded into one because they always
shared a single release cadence — `Mcp::ToolSpec` reads `Primitives`
constants live, so the two could never actually version independently. See
[`docs/plans/mud_manager/single_gem.md`](../../docs/plans/mud_manager/single_gem.md)
for the full rationale.

The namespace still marks the internal boundary — `MudManager::Session` /
`MudManager::Primitives` (domain) vs. `MudManager::Mcp::*` (interface) — it
just doesn't charge a second `gem install` for it.
