require_relative "world"

module MudManager
  module Map
    # Search over the map.
    #
    # The pathfinder takes state as a parameter (§3). We never mutate the graph
    # when the character picks up a key: edges carry predicates and those are
    # evaluated against a `state` passed in. That buys counterfactual queries,
    # and those are how subgoals get *derived* rather than guessed — "could I
    # reach the crypt if I held the brass key?" If yes, "get the brass key" is
    # a subgoal discovered from the map.
    #
    # It is Dijkstra rather than BFS because the edges genuinely differ: a
    # plain exit costs 1, a shut door costs more, an edge that needs a boat you
    # do not have is infinite. Uniform-cost search cannot express "go the long
    # way around the ogre".
    module Pathfinder
      INFINITY = Float::INFINITY

      COST = {
        open:           1,
        unknown:        1,
        closed_door:    3,
        needs_item:     5,
        blocked_by_mob: 8,
        no_exit:        INFINITY
      }.freeze

      # What a `state` must contain for an edge of each status to be usable.
      # `needs_item` edges name their own requirement (["boat"]).
      GATE = {
        closed_door:    ["open_doors"],
        blocked_by_mob: ["pass_mobs"],
        no_exit:        ["impossible"]
      }.freeze

      Step  = Struct.new(:direction, :from, :to, :edge, keyword_init: true)
      Route = Struct.new(:steps, :cost, :target, keyword_init: true) do
        def directions = steps.map(&:direction)
        def length     = steps.size
      end

      module_function

      # Preconditions for traversing `edge`, as fact keys to look up in state.
      def requirements(edge)
        return Array(edge.requires) if edge.status == :needs_item
        GATE.fetch(edge.status, []) | Array(edge.requires)
      end

      def traversable?(edge, state)
        return false if edge.to.nil?
        requirements(edge).all? { |fact| state[fact] || state[fact.to_s] }
      end

      def cost(edge) = COST.fetch(edge.status, 1)

      # Shortest route between two known rooms. nil when no route exists under
      # `state` — which is itself the useful answer for a counterfactual query.
      def route(world, from:, to:, state: {})
        return nil if from.nil? || to.nil?
        return Route.new(steps: [], cost: 0, target: to) if from == to

        prev, = dijkstra(world, from, state) { |id| id == to }
        build_route(prev, from, to)
      end

      # §6.7, two navigation modes, and the destination decides which. When the
      # destination is not a known node you are expanding the boundary, and the
      # right choice is the unexplored exit cheapest to reach *from where you
      # are now* — a search to the nearest frontier edge rather than an
      # arbitrary pick. That is what stops exploration ping-ponging across the
      # map.
      #
      # Returns [Route to the room holding the frontier edge, the frontier Edge].
      def nearest_frontier(world, from:, state: {})
        return [nil, nil] if from.nil?

        frontier = world.frontier_edges.reject { |e| gated?(e, state) }
        return [nil, nil] if frontier.empty?

        by_room = frontier.group_by(&:from)
        return [Route.new(steps: [], cost: 0, target: from), pick(by_room[from])] if by_room.key?(from)

        # dijkstra stops on the first settled hit, so it is the nearest one.
        prev, reached = dijkstra(world, from, state) { |id| by_room.key?(id) }
        return [nil, nil] unless reached

        [build_route(prev, from, reached), pick(by_room[reached])]
      end

      # §6.7: for destinations you return to constantly (temple, shop, guild),
      # run one single-source shortest path *from* the destination over
      # reversed edges and keep the field. Navigation then becomes greedy
      # descent — from any room, step to the neighbour with the lower number.
      # No search per move.
      #
      # This is a derived index in the sense of §6.1: a cache over rooms and
      # edges, rebuilt whenever they change, never a second source of truth.
      def distance_field(world, to:, state: {})
        dist = { to => 0 }
        queue = [[0, to]]
        incoming = world.edges.values.group_by(&:to)

        until queue.empty?
          queue.sort_by!(&:first)
          d, node = queue.shift
          next if d > dist.fetch(node, INFINITY)

          Array(incoming[node]).each do |edge|
            next unless traversable?(edge, state)
            nd = d + cost(edge)
            next if nd >= dist.fetch(edge.from, INFINITY)
            dist[edge.from] = nd
            queue << [nd, edge.from]
          end
        end
        dist
      end

      # Greedy descent over a precomputed field: one step, no search.
      def descend(world, field, from:, state: {})
        here = field[from]
        return nil if here.nil? || here.zero?
        best = world.edges_from(from)
                    .select { |e| traversable?(e, state) }
                    .min_by { |e| field.fetch(e.to, INFINITY) + cost(e) }
        return nil if best.nil? || field.fetch(best.to, INFINITY) >= here
        best
      end

      # ── internals ───────────────────────────────────────────────────────────

      # Returns [predecessor map { room_id => Step }, the accepted node or nil].
      # Stops as soon as the block accepts a settled node, which under Dijkstra
      # is the cheapest such node.
      def dijkstra(world, from, state)
        dist  = { from => 0 }
        prev  = {}
        queue = [[0, from]]
        seen  = {}
        hit   = nil

        until queue.empty?
          queue.sort_by!(&:first)
          d, node = queue.shift
          next if seen[node]
          seen[node] = true

          if node != from && yield(node)
            hit = node
            break
          end

          world.edges_from(node).each do |edge|
            next unless traversable?(edge, state)
            c = cost(edge)
            next if c == INFINITY
            nd = d + c
            next if nd >= dist.fetch(edge.to, INFINITY)
            dist[edge.to] = nd
            prev[edge.to] = Step.new(direction: edge.direction, from: node, to: edge.to, edge: edge)
            queue << [nd, edge.to]
          end
        end

        [prev, hit]
      end

      def build_route(prev, from, to)
        return nil unless prev.key?(to) || from == to
        steps = []
        node  = to
        while node != from
          step = prev[node] or return nil
          steps.unshift(step)
          node = step.from
          return nil if steps.size > 10_000
        end
        Route.new(steps: steps, cost: steps.sum { |s| cost(s.edge) }, target: to)
      end

      def gated?(edge, state)
        reqs = requirements(edge)
        !reqs.all? { |f| state[f] || state[f.to_s] }
      end

      # Prefer a plain unexplored exit over one already known to be doored.
      def pick(edges)
        list = Array(edges)
        list.find { |e| e.status == :unknown } || list.first
      end
    end
  end
end
