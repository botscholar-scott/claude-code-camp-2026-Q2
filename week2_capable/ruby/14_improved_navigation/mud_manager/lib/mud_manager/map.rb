require_relative "map/observation"
require_relative "map/parser"
require_relative "map/world"
require_relative "map/projection"
require_relative "map/pathfinder"
require_relative "map/store"
require_relative "map/renderer"
require_relative "map/cartographer"

module MudManager
  # The map (epic 14_improved_navigation).
  #
  # The agent's loop works; what it lacked was a world model, so it walked in
  # circles and paid for every step — 1.7M input tokens bought 50 moves, about
  # 34,000 input tokens per step through a doorway. This is the structural fix:
  # a room graph derived from what the agent has already observed, plus a
  # search over it.
  #
  #   Parser       screen text            -> Observation
  #   Projection   (world, call, result)  -> world          the single fold step
  #   World        rooms, edges, position                   the stored artifact
  #   Pathfinder   world + state          -> route          Dijkstra, §3
  #   Store        world                  <-> disk
  #   Cartographer live glue + walking with per-step verification
  #   Renderer     world                  -> graph paper (write-only)
  #
  # Two graphs, not one (§2). This is the map: nodes are rooms, edges are
  # exits, dense and spatial and searched constantly. The dependency graph
  # ("hold the brass key", "level >= 25") is deliberately NOT here. They touch
  # at exactly one point — a map edge is traversable only if certain facts
  # hold — which is why Pathfinder takes `state` as a parameter instead of the
  # map mutating when you pick something up.
  module Map
  end
end
