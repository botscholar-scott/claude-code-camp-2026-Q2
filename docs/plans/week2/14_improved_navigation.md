# `14_improved_navigation` — the map

**Target:** `week2_capable/ruby/14_improved_navigation`
**Extracted:** 2026-07-30 from §12 and §16.2 of `13_key_fixes.md`
**Depends on:** `13_key_fixes` (landed: F34, F35, F4, F25, F23, F5)

The agent's loop works. What it lacks is a world model, so it walks in circles
and pays for every step. This epic builds the map: a room graph derived from
what the agent has already observed, plus a search over it.

§7 records where this document corrects the text it was extracted from. Read it
before treating any inherited claim as verified.

---

## 1. Why: what one session actually cost

Measured from `.boukensha/sessions/20260728T020721Z-11017d94.jsonl`, a real
tbaMUD run on `claude-haiku-4-5` (200k window, `max_turn_tokens` 60,000,
`max_iterations` 25):

| | |
|---|---|
| turns | 24 |
| turns that died exhausting the turn budget | **18** |
| turns that completed | 6 |
| API calls | 110 |
| input tokens | **1,698,189** |
| output tokens | 8,984 |
| input : output ratio | **189 : 1** |
| median input per call | 15,001 |
| largest single call | 26,536 |
| tool calls | 86 |
| of those, `tbamud__move` | 50 |
| of those, `fs__*` | **0** |
| session cost | $0.35 |

Three quarters of all turns died without finishing, most after only 3 to 7
iterations. 1.7M input tokens bought 50 moves: roughly **34,000 input tokens per
step through a doorway**. Almost none of that is the model thinking. It is the
same history and the same 40 tool schemas re-sent on every call.

The structural fix is the map. Caching (F22) is a multiplier on top of it and is
deliberately scheduled after, in `15_context_economy`.

---

## 2. Two graphs, not one

The temptation is to put everything in the room graph: mark this edge "needs
brass key", mark that room "level 25+". Resist it, or you get a pathfinder that
knows about quests and a quest system that knows about geography.

**The map.** Nodes are rooms, edges are exits. Dense, spatial, stable once
observed, searched constantly.

**The dependency graph.** Nodes are facts and objectives: "hold the brass key",
"level >= 25", "1,000 gold", "the priest is friendly". Edges are *achieves* and
*requires*. Sparse, grows as you learn, searched when deciding what to do next.

They touch at exactly one point: **a map edge is traversable only if certain
facts hold.** The locked door is an edge with a precondition. The angry mob is an
edge whose cost is a function of your level. Keeping the interface that narrow is
what stops the two from contaminating each other.

Only the map is in scope for this epic. The dependency graph is described here so
the map's interface does not foreclose it.

---

## 3. The pathfinder takes state as a parameter

Don't mutate the graph when you get a key. Annotate edges with predicates and
evaluate them against a state passed in:

```
path(from:, to:, state:)   # skips edges whose preconditions fail in `state`
```

This buys counterfactual queries, and those are how subgoals get *derived*
instead of guessed: "could I reach the crypt if I held the brass key?" If yes,
"get the brass key" is now a subgoal, discovered from the map. The same query
turns a level requirement into a subgoal.

It is also where Dijkstra earns its keep over BFS. With mobs in play the edges
genuinely differ: a plain exit costs 1, a beatable mob costs expected damage plus
time, an unbeatable one is infinite. Uniform-cost search cannot express "go the
long way around the ogre".

---

## 4. Where the model belongs, and where it does not

**Model:** propose decompositions, read prose into facts, resolve genuine
ambiguity, choose between alternatives when the choice is not mechanical.

**Code:** hold the goal stack, evaluate preconditions, run the search, execute
the movement batch, classify failure, remember what has already been tried.

The model is good at world knowledge and bad at bookkeeping. Every piece of state
left in its head is paid for on every subsequent call, and it still gets it wrong.

### 4.1 Failed attempts have to be durable

Big goals decompose N ways and nothing is known in advance, so failure is the
normal case. A goal stack that records only what to do next will retry what just
failed, forever. Each objective needs to carry which alternative it is on, what
has been ruled out, and why, **in the structured store rather than the
transcript**, because the transcript is exactly what gets dropped.

This is also the answer to the context problem. With this shape the map, the
facts and the dead ends live in a store; each subgoal runs in a fresh short
context holding its goal plus the facts relevant to it; the parent gets one line
back. Compaction stops being load-bearing and goes back to being a seatbelt.

---

## 5. What tbaMUD actually hands you

Read out of the session logs. Better than feared in one way, worse in three.

**Exits are enumerated, not inferred.** Every room result carries a literal
`[ Exits: n e s w ]` line. Edges are directly observable, so the map does not
need prose inference to be built. `u` and `d` both appear, so the direction set is
the full six. Measured: 94 of the 99 recorded move results carry an exits line.

**Closed doors are pre-announced in that same line.** A parenthesised direction
means a door that is shut: `[ Exits: n s (w) ]`, `[ Exits: e (s) w ]`,
`[ Exits: (n) (e) s w ]`. The one time a parenthesised exit was walked, the reply
was `The door seems to be closed.` So an edge can be marked as door-bearing
**before** you ever try it, from the same line that gives you the exit set, and
the failure text on traversal is a distinct, greppable string. That is the
cheapest possible version of §8 step 2: no prose inference needed for the common
case.

**Free state.** The status prompt is embedded in the output (`25H 100M 80V >`),
so hit points, mana and movement points come for free on every call and can feed
the fact store without a separate `check`.

**Two tools are already the sensors this design needs.** `tbamud__consider` is a
mob-difficulty oracle, which is the edge-weight input for §3. `tbamud__track` is
tbaMUD's own tracking skill, worth measuring against a local search before
duplicating it.

**The colour codes are structure, not noise. Do not strip them first.** Every
line carries ANSI, and two codes delimit the room block exactly:

| code | colour | what it marks | count in corpus |
|---|---|---|---|
| `ESC[0;33m` | yellow | the room title | 104 of 105 room observations |
| `ESC[0;36m` | cyan | the `[ Exits: ]` line | 105 of 105 |

So the parser anchors on colour: **the title is the first `ESC[0;33m` line, the
exits are the `ESC[0;36m` line, the description is everything between them, and
mobs and objects are everything after.** That is 105 of 105, including the one
async event, because `The Mayor says 'Good day, citizens!'` carries no colour
code at all and is skipped rather than needing a speech heuristic.

Stripping ANSI before parsing throws away the most reliable signal on the screen.
An earlier draft of this document said to strip it. That was wrong.

**Room titles are clean, and repeat.** Main Street (12 observations), Market
Square (8), The Common Square (8), The Temple Of Midgaard, The Bakery. 34
distinct titles across the corpus. "Main Street" covers three physically distinct
rooms, so the title is a strong recognition signal but not a key on its own.

**Descriptions are stable across visits, and that is what makes a key.** Of 23
titles visited more than once, 21 had a byte-identical description every time.
The two that varied, Main Street and The Great Field Of Midgaard, varied because
those titles cover several different rooms. Mobs and objects do not pollute this,
because they appear *below* the exits line. §6.2 builds identity on it.

**Some rooms cannot be identified at all.** A dark room returns
`It is pitch black...` with no title, no description and no exits. Identity there
depends on movement history or a light source.

No room vnum is exposed anywhere in the transcript.

### 5.1 Failure vocabulary is only partly known

Confirmed present in the corpus, with counts:

| reply | count | meaning |
|---|---|---|
| `The door seems to be closed.` | 1 | closed door, pre-announced by parentheses |
| `You need a boat to go there.` | 2 | edge requires an item |
| `It is pitch black...` | 2 | move **succeeded**, room unidentifiable |

Those 5 are exactly the 5 move results that carry no exits line, so **every one
of the 99 recorded moves is classifiable**: 94 arrivals with a room, 2 arrivals
in the dark, 3 refusals. Nothing is unexplained.

That is a property of this corpus, not of tbaMUD. Not present in any session, so
their exact wording is **unverified**: "you can't go that way" for a non-existent
exit, and any mob-blocks-movement message. The parser must not assume it has seen
the whole taxonomy, and an unrecognised reply has to be treated as "position
unknown, re-localize" rather than as a successful move.

---

## 6. How the map gets recorded

The atom is the traversal event, `(from, direction, to)`. Everything else is
derived from a sequence of those.

Every number quoted in this section was measured by projecting the 99 recorded
moves in the two corpus files of §7.2. Nothing here is estimated.

### 6.1 The map is a stored artifact

The map is written as you play and loaded at boot. It is **not** re-derived from
the session logs. Those logs are a debug trace: 283KB of jsonl bought 49 moves,
most of it blind wandering, and reconstructing a route table from a transcript of
getting lost is backwards. The map for those same moves is a few KB.

This is the point of the epic. Play for fifty hours, map the city, come back
tomorrow, and boukensha already knows the way to the bakery.

| artifact | role | lives |
|---|---|---|
| rooms + edges + last position | **the map**, stored and loaded | `.boukensha/` |
| distance fields, frontier list | search indexes | rebuilt from the map, disposable |
| graph paper (markdown) | human-readable render | write-only, never read back |
| session jsonl | debug trace | not an input to the map |

| table | contents |
|---|---|
| rooms | UUID, title, description hash, exit set, doors, dead-reckoned coords, flags (dark, shop, guild) |
| edges | from, direction, to (**may be unknown**), status, evidence seq, last confirmed |
| position | the UUID the player was last known to be standing in |

`position` is what makes the next session start instantly. Boukensha quits, the
character stays put, so tomorrow it resumes from that UUID and routes
immediately. Re-localization by recognition (§6.2) is the recovery path for when
that trust breaks: you moved the character by hand, died, or recalled.

The graph paper is a render, never an input. A rendered map cannot disagree with
the map; a second file you both write and read will drift. It is also not for the
agent. Dropping a map document into context on every call rebuilds §1's 189:1
ratio in a new costume. The agent reaches the map through a tool that answers a
question ("take me to the bakery") and gets back a direction list.

### 6.2 Identity is `(title, description)`

The room block is colour-delimited (§5), so both fields parse reliably. Identity
is the pair, hashed. Dead reckoning is what discovers *edges*; it is no longer
what establishes identity.

Measured across the corpus: 34 distinct titles yield **37 distinct
`(title, description)` pairs**, which is exactly the room count obtained
independently by unioning the two sessions (24 + 31 − 18 shared). Of 23 titles
visited more than once, 21 had a byte-identical description every time. The two
that varied, Main Street and The Great Field Of Midgaard, varied because those
titles cover several different rooms, which the description separates and the
title alone cannot.

Three things fall out:

- **Re-localization is one `look`.** No confirming walk, no coordinate frame.
- **Cross-session stitching needs no shared origin**, which is what makes a
  fifty-hour map usable on day two.
- **Duplicate titles stop mattering.** Three Main Streets are three keys.

Coordinates are still recorded, because they make the map drawable and they break
ties (§6.4). They are corroboration now, not the key.

**This is a strong signal, not a proof.** 37 rooms is a small sample and
CircleMUD zones do exist where descriptions repeat, mazes and forest in
particular. §6.4 is what catches that.

### 6.3 Minting is conditional

Go `n,n,w,d` to reach B. Now go `n,n,w,e,w,d`. The `e` then `w` is a round trip,
so both routes end at the same room. A scheme that mints a UUID on every arrival
gives the second route a *different* node, and B becomes two places. Two routes
to one room stop being two routes and become a phantom wing of the building.

So on arrival:

- hash `(title, description)`. If a room with that key exists, you are standing
  in it. Reuse it.
- otherwise mint a new UUID.
- a dark room has neither field, so identity there falls back to dead reckoning.

A projection keyed on coordinate plus attributes, run over the 99 recorded moves,
gives the shape of the win:

| | unconditional mint | conditional mint |
|---|---|---|
| nodes, session 1 (50 moves) | 50 | **26** |
| nodes, session 2 (49 moves) | 46 | **31** |
| arrivals that reused a node | 0 | 39 |
| immediate there-and-back moves | 16 | 16 |
| nodes reachable by >1 distinct inbound edge | 0 | **20** |
| edge conflicts (same from+dir, two destinations) | n/a | **0** |
| exit-set conflicts on revisit | n/a | **0** |

Roughly half of every map built by unconditional minting is phantom. The
`e`-then-`w` case occurs 16 times, and 20 rooms turn out to be reachable by more
than one distinct route. Capturing that is the point.

Those numbers came from the coordinate-keyed projection that predated §6.2. The
`(title, description)` key has its own evidence, the 37-versus-37 agreement
above, and re-running the projection under it is the first task of step 1.

**Zero conflicts is not proof.** It proves no traversal ever contradicted a
merge. A wrong merge never subsequently contradicted stays invisible. The answer
is not a stronger check at merge time, it is making merges reversible (§6.5).

### 6.4 What the key cannot fix

Two genuinely different rooms with the same title *and* the same description
collide under §6.2 and get wrongly merged. Mazes and forest zones are where this
happens.

Dead reckoning catches it, because a wrong merge warps the coordinates: the same
node ends up claimed at two positions that no sequence of moves can reconcile.
That is a contradiction, and §6.6's invariants surface it.

The confirming walk settles it. Pick an exit whose destination is already
recorded for the merged node, walk it, and check whether you land where
predicted. Confirmed, the merge stands. Refuted, split it (§6.5). One move buys
certainty.

So the two mechanisms swap roles from the previous draft: attributes decide,
movement audits.

### 6.5 Merges must be reversible

Because a wrong merge is discovered late, by contradiction, the projection has to
be able to *split* a node it previously merged, not only join. That is what the
`evidence seq` column on edges is for: every edge records the observation
sequence that established it, so a node can be taken back apart and its edges
reassigned to the right side of the split. Without it a single bad merge is
permanent and silently poisons every path through that room.

### 6.6 Verification is self-derived

No world file is ever read. The map is checked against itself and against the
game, using only what the agent observed by walking:

- **Edge invariant.** The same room and the same direction must always lead to
  the same node. 0 violations in 99 moves.
- **Exit-set invariant.** Revisiting a node must observe the exit set already
  recorded for it. 0 violations in 99 moves.
- **Degree invariant.** A room announcing four exits can never accumulate a fifth
  outbound edge.
- **The confirming walk** (§6.4), which is an in-game action and the only check
  that can settle a suspected wrong merge of two same-key rooms.

A violation of any of the first three is a wrong merge surfacing, and §6.5 is how
it gets undone.

### 6.7 Frontier, reverse edges, and search

**Never auto-create the reverse edge.** A north from A to B does not imply a
south from B to A. Record only the traversal you made and let the reverse be
discovered. In the session 1 render, edges confirmed in both directions and edges
seen in only one are visibly different things.

**Frontier edges are the whole point.** `[ Exits: n e s w ]` tells you a room has
four exits *before* you have walked any of them, so every visited room
contributes unvisited edges. Session 1 ends with 26 rooms, 41 edges walked and
**29 exits never tried**. Recording an edge with `to = unknown` turns "find
location X" from wandering into a search with a real frontier, and gives you
"nearest unexplored exit" for free. Without it, exploration has no plan and you
are back to the 189:1 ratio.

**Two navigation modes, and the destination decides which.** If the destination
is a known node, search the graph. If it is not, you are expanding the boundary,
and the right choice is the unexplored exit that is cheapest to reach *from where
you are now*, which is a search to the nearest frontier edge rather than an
arbitrary pick. That is what stops exploration ping-ponging across the map.

**Searching backwards from a hub is worth doing deliberately.** For destinations
you return to constantly (temple, shop, guild), run one single-source shortest
path *from* the destination over reversed edges and keep the resulting distance
field. Navigation then becomes greedy descent: from any room, step to the
neighbour with the lower number. No search per move, and the field survives until
the map changes. This is a derived index in the sense of §6.1: a cache over rooms
and edges, rebuilt whenever they change, never a second source of truth.

**Edge status is where step 2 of §8 lives.** `open` / `locked` / `blocked_by_mob` /
`one_way_suspected` / `unknown`, each carrying the observation sequence that
established it. That is what lets the search route around the ogre, and what lets
you audit why it did.

**Execution needs verification, not faith.** A path is a direction sequence, and
each step should confirm that arrival matches the expected node. On mismatch,
stop and re-localize rather than continuing blind. A map-follower that assumes its
own moves worked is F34 all over again, one layer up.

---

## 7. Corrections to the inherited text

Both of these were established by running code this session, not by reading. They
change what step 2 of the build order depends on.

### 7.1 F34 is not the blocked-move sensor

§12.8 of the source document argued that a blocked move returns `isError: true`,
that `tools/mcp.rb` flattened it into prose, and that fixing F34 would therefore
make failed moves visible. **The first premise is false.**

`mud_manager/lib/mud_manager/mcp/server.rb:104` sets `isError: true` for exactly
one thing, a rescued `ProtocolError`, and there are six codes:
`connection_error`, `timeout`, `login_error`, `not_configured`, `argument_error`,
`unknown_tool`. A closed door is an ordinary command round-trip that succeeded,
so mud-manager returns `isError: false`, correctly.

Consequences for this epic:

- **Blocked moves must be detected from game text**, using the parenthesis
  convention in §5 and the distinct failure strings in §5.1. There is no flag to
  read.
- **Step 2 of §8 does not depend on F34.** The source build order says "Requires
  F34 first"; it does not.
- What F34 actually bought is a truthful `ok` flag for MCP-level failures, which
  the replay projection should treat as "this call is not an observation" rather
  than as a blocked move.

### 7.2 The corpus is smaller than stated

The source text gives two different figures ("ten session files ... 50 real
moves" in §12.7, "eleven session files ... 129 moves" in §16.2). Measured:

| | |
|---|---|
| session files on disk | 12 |
| files containing any navigation | **2** |
| moves across those two | **99** (50 + 49) |
| tool results across those two | 177 |
| move results carrying an exits line | 94 |
| tool results logged `ok: false` | **0** (all predate F34) |

The other ten files hold 0 to 3 tool calls each and are not useful as a corpus.
99 moves in two runs is still enough to harden a parser offline, but it is two
trajectories, not eleven, so coverage of unusual rooms is thin.

### 7.3 Replay pairing, now half-fixed

§12.7 notes that `tool_call` and `tool_result` pair only by position, because the
logger dropped the `tool_use_id`. F35 has landed, and the newest session file
(`20260730T181839Z-dbd21b88.jsonl`) carries `tool_use_id` on every tool result,
confirmed in a live run.

But the two files that actually contain the 99 moves **predate the fix** and have
no ids. So the replay projection needs to accept both: pair by `tool_use_id` when
present, fall back to position when absent. Dispatch was a serial `each` in the
code that wrote those files, so positional pairing is sound for them specifically.

---

## 8. Build order

Smallest thing that gets most of the value:

1. **Map plus search over observed rooms.** No predicates, no weights. "Take me
   to a room I have seen." This alone kills the wander-and-re-`look` loop that
   produced the 189:1 ratio in §1.
2. **Edge annotations learned from failure.** Try north, get "the door is
   locked", mark the edge. The pathfinder routes around it with no planner
   involved. Detected from game text, not from a flag (§7.1).
3. **A fact store** (level, inventory, gold, HP from the prompt line) and edge
   predicates referencing it. Weights and counterfactual queries turn on here.
4. **Goal decomposition** over the dependency graph.

Steps 1 and 2 are most of the win and need no planner. Whether step 4 is needed
at all, or whether a good map plus learned obstacles plus a human-supplied
ordering of the big objectives is enough, is worth deciding after step 3 rather
than before step 1.

### 8.1 Build it as a replay first

The map is stored, not derived (§6.1), but the thing that *updates* it should be
a pure function: `(map, tool_name, args, result) -> map`. Live, it is fed one
observation at a time. For development it can be fed a recorded session instead,
which is the same function in a loop.

That is what makes the corpus useful without making it authoritative. The two
files carry 99 real moves complete with ANSI codes, the interleaved Mayor
broadcast, two pitch-black rooms, five parenthesised-door exit lines, one real
closed-door failure and two boat refusals, with no MUD running and no tokens
spent. Harden the parser and the merge rule there, then point the same function
at the live stream. §6's measurements came out of exactly this and are the
cheapest available proof that the idea works: the invariants of §6.6 hold across
both files.

### 8.2 World files are out of bounds

An earlier draft of this document proposed using
`week0_explore/circlemud-world-parser/` to dump tbaMUD's true room graph and
verify the discovered map against it. **That is not allowed and is recorded here
so it does not get proposed again.** The world parser was a week0 exploration
tool. Nothing derived from the game's data files enters the map, its fixtures or
its tests, in any form, including as an oracle.

The agent works it out by walking and writing on graph paper. Verification is
self-derived, per §6.6: the edge, exit-set and degree invariants, plus the
confirming walk. The cost of that is honest and worth stating: a wrong merge is
not caught at merge time, it is caught when a later traversal contradicts it,
which is why §6.5 requires merges to be reversible.

---

## 9. Open questions for review

1. **Who owns the map and where does it live?** ADR 0012 says boukensha ships no
   tools, which points at a second MCP server. Against that, F23 deleted the
   `filesystem` server precisely because its schemas cost ~2,010 tokens per call
   for zero calls; three map tools is ~430 tokens per call against a median
   15,001. Not mud_manager either way: that gem is reused unmodified and the
   telnet layer should not know what a map is.
2. **How does the map see the moves?** Tail boukensha's session trace, or sit in
   front of `mud-manager --mcp` as a proxy and see real request/response pairs.
   The proxy deletes the pairing problem of §7.3 rather than working around it,
   at the cost of being a man in the middle that can break the MUD outright.
3. **Is `tbamud__track` good enough to skip step 1 for known destinations?** §5
   flags it as worth measuring first. Nobody has run it. It cannot remove the
   need for the map, since it only helps for destinations already known and §1's
   189:1 ratio was burned exploring.

### Closed by measurement

4. ~~**How is loop closure verified in the replay?**~~ **Resolved, and then
   made mostly moot.** Closure is settled at arrival by hashing
   `(title, description)`, which the corpus shows is a near-unique room key: 37
   distinct pairs against 37 rooms derived independently. No live move is needed.
   The confirming walk survives only as the audit for two rooms that share both
   fields. See §6.2 and §6.4.
5. ~~**Does the map survive `max_output_tokens` truncation?**~~ **Resolved for
   this corpus, unverifiable beyond it.** Across 228 responses in the two corpus
   files, `stop_reason` is only ever `end_turn` or `tool_use`, never
   `max_tokens`. The 39 `limit_reached` records are `kind=max_tokens` against the
   *turn* budget (60k, overshot to 85k), which ends a turn between iterations
   rather than mid-reply. So no started-and-never-dispatched move exists in the
   corpus and the projection cannot be hardened against that case offline. Guard
   it by construction instead: an observation is a `tool_call` paired with a
   `tool_result`, and an unpaired call is not an observation.
