require_relative "../primitives"
require_relative "world"
require_relative "projection"
require_relative "pathfinder"
require_relative "store"

module MudManager
  module Map
    # Cartographer is the live half of the map: it holds the World, folds every
    # observation into it, persists it, and answers the three questions the
    # agent is allowed to ask.
    #
    # It exists because of §6.1's last paragraph. Dropping a map document into
    # context on every call rebuilds §1's 189:1 ratio in a new costume. The
    # agent never sees the map; it asks a question ("take me to the bakery")
    # and gets back a short answer.
    class Cartographer
      P = MudManager::Primitives

      # Walking a long route inside one tool call is the entire point (it is
      # what collapses N model round-trips into one), but an unbounded walk on
      # a stale map is how you end up somewhere unexplained.
      MAX_STEPS = 40

      attr_reader :world, :store

      # runner: callable taking a Primitives::Command and returning the MUD's
      # response text. Injected so the map can be exercised with no MUD.
      def initialize(runner:, world: nil, store: nil)
        @runner = runner
        @store  = store
        @world  = world || store&.load || World.new
      end

      # ── the fold (§8.1) ─────────────────────────────────────────────────────

      # Every gameplay call the daemon executes passes through here. Live, the
      # server that runs the move has the direction and the result in the same
      # place, so nothing has to tail a log or correlate by position (§9.1).
      def observe(tool_name, args, result, ok: true)
        res = Projection.apply(@world, tool_name, args, result, ok: ok)
        persist
        res
      end

      def persist
        @store.save(@world) if @store && @world.dirty?
      end

      # ── the three questions ─────────────────────────────────────────────────

      # Where am I, and what is around me? Re-localization is one `look`
      # (§6.2), which is what makes a map built yesterday usable today.
      def where(relocalize: true)
        observe("look", {}, @runner.call(P.look)) if relocalize

        room = @world.current
        return "Position unknown and the room could not be identified. " \
               "Try again, or move once and look." if room.nil?

        label_exits if needs_exit_listing?(room)
        room = @world.current

        known, unknown = @world.edges_from(room.id).partition { |e| e.to }
        lines = ["You are in #{room.title}.#{room.dark? ? ' (dark)' : ''}"]
        lines << "Known exits: #{known.map { |e| "#{e.direction} -> #{@world.room(e.to)&.title || '?'}#{status_note(e)}" }.join(', ')}" unless known.empty?
        lines << "Unexplored exits: #{unknown.map { |e| "#{e.direction}#{expected_note(e)}#{status_note(e)}" }.join(', ')}" unless unknown.empty?
        lines << "This room's exits have changed since it was last seen, so it may be two " \
                 "different rooms recorded as one. Walk a known exit to settle it." if room.suspect?
        lines << "Map: #{@world.room_count} rooms, #{@world.frontier_edges.size} unexplored exits."
        lines.join("\n")
      end

      # One `exits` call names the room behind every visible exit. That is up
      # to six edges labelled for the price of one MUD round trip, each of
      # which would otherwise cost a walk to discover. Worth doing whenever
      # this room still has an exit nobody has named or walked.
      def label_exits
        observe("check", { "kind" => "exits" }, @runner.call(P.info_self("exits")))
      end

      # Ask once per room. A second listing of a room whose exit set has not
      # changed says exactly what the first one said, and directions the
      # listing omitted stay unnamed rather than being guessed at — we have
      # never observed what `exits` does with a shut door.
      def needs_exit_listing?(room)
        room && room.listed_seq.nil?
      end

      # "Take me to the bakery." Resolves a name against rooms already seen,
      # searches the graph, then walks it — verifying each arrival.
      def goto(destination, state: {})
        return "I do not know where I am. Call map_where first." if @world.position.nil?

        matches = search(destination)
        doorway = named_frontier(destination, state)

        if matches.empty? && doorway.nil?
          return "Nothing I have seen or been told about matches #{destination.inspect}. " \
                 "Use map_explore to expand the map."
        end

        route, target = best_route(matches, state)

        # A room named by an `exits` listing but never entered is still a real
        # destination: we were told what is through that doorway, we have just
        # never walked it. Prefer a room we have actually stood in when both
        # are reachable and the visited one is no further.
        if doorway && (route.nil? || doorway[:cost] < route.cost)
          return walk_through(doorway)
        end

        if route.nil?
          return "I know #{matches.size} room(s) matching #{destination.inspect} but no route " \
                 "from here avoids the blocked edges. Try map_explore."
        end

        return "You are already in #{@world.room(target).title}." if route.steps.empty?

        note = matches.size > 1 ? " (#{matches.size} rooms share that name; routing to the nearest)" : ""
        walk(route, "#{@world.room(target).title}#{note}")
      end

      # Walk to the room holding a named-but-unwalked exit, then take it. The
      # arrival is what settles whether the name was telling the truth.
      def walk_through(doorway)
        edge  = doorway[:edge]
        route = doorway[:route]

        unless route.steps.empty?
          approach = walk(route, "the way to #{edge.expected_title}")
          return approach unless @world.position == edge.from
        end

        res = step(edge.direction)
        case res.outcome
        when :arrived
          "Arrived at #{res.room.title} (never visited before, reached through the #{edge.direction} " \
            "exit that was listed as leading there)."
        when :arrived_dark
          "Went #{edge.direction} toward #{edge.expected_title} but the room is pitch black."
        when :refused
          "The #{edge.direction} exit toward #{edge.expected_title} is blocked " \
            "(#{res.observation.reason}); marked on the map."
        else
          "Went #{edge.direction} but could not identify the room; position unknown, call map_where."
        end
      end

      # Expand the boundary. §6.7: the right choice is the unexplored exit
      # cheapest to reach from where you are now, not an arbitrary one — that
      # is what stops exploration ping-ponging across the map.
      def explore(state: {})
        return "I do not know where I am. Call map_where first." if @world.position.nil?

        route, edge = Pathfinder.nearest_frontier(@world, from: @world.position, state: state)
        return "No unexplored exits left in the map I have. Walk somewhere new." if edge.nil?

        unless route.steps.empty?
          approach = walk(route, "the nearest unexplored exit")
          return approach unless @world.position == edge.from
        end

        res = step(edge.direction)
        # A room just discovered has a whole unlabelled frontier of its own,
        # and one call names all of it.
        label_exits if needs_exit_listing?(res.room)

        case res.outcome
        when :arrived      then "Explored #{edge.direction} -> #{res.room.title}. #{frontier_note}"
        when :arrived_dark then "Explored #{edge.direction} -> a pitch-black room. #{frontier_note}"
        when :refused      then "#{edge.direction} is blocked (#{res.observation.reason}); marked on the map. #{frontier_note}"
        else                    "Moved #{edge.direction} but could not identify the room; position lost, call map_where."
        end
      end

      # ── walking ─────────────────────────────────────────────────────────────

      # §6.7: execution needs verification, not faith. Each step confirms that
      # arrival matches the expected node; on mismatch we stop and re-localize
      # rather than continuing blind. A map-follower that assumes its own moves
      # worked is F34 all over again, one layer up.
      def walk(route, description)
        taken = []
        route.steps.take(MAX_STEPS).each do |st|
          res = step(st.direction)

          case res.outcome
          when :arrived, :arrived_dark
            taken << st.direction
            next if res.room.id == st.to
            return "Stopped after #{taken.join(',')}: expected #{@world.room(st.to)&.title} " \
                   "but arrived in #{res.room.title}. The map was wrong there and is now corrected. " \
                   "Re-run map_goto to continue."
          when :refused
            return "Stopped after #{taken.join(',')}: #{st.direction} is blocked " \
                   "(#{res.observation.reason}). Marked on the map — re-run map_goto to route around it."
          else
            return "Stopped after #{taken.join(',')}: unrecognised reply moving #{st.direction}. " \
                   "Position unknown; call map_where to re-localize."
          end
        end

        if route.steps.size > MAX_STEPS
          return "Walked #{taken.size} steps toward #{description} (#{taken.join(',')}); " \
                 "route is longer than #{MAX_STEPS} steps, call map_goto again to continue."
        end

        "Arrived at #{description} in #{taken.size} moves: #{taken.join(',')}."
      end

      def step(direction)
        observe("move", { "direction" => direction }, @runner.call(P.move(direction)))
      end

      # ── lookup ──────────────────────────────────────────────────────────────

      # Titles are clean and they repeat: "Main Street" covers three physically
      # distinct rooms (§6.2). So a name is a filter, not a key, and the search
      # returns every match and lets the router pick the nearest.
      def search(query)
        q = query.to_s.strip.downcase
        return [] if q.empty?
        rooms = @world.rooms.values.reject(&:dark?)
        exact = rooms.select { |r| r.title.downcase == q }
        return exact unless exact.empty?
        rooms.select { |r| r.title.downcase.include?(q) }
      end

      # The cheapest unwalked exit whose listed destination matches the query:
      # the cost of reaching the room it leaves from, plus the step itself.
      def named_frontier(query, state)
        q = query.to_s.strip.downcase
        return nil if q.empty?

        best = nil
        @world.named_frontier_edges.each do |edge|
          title = edge.expected_title.downcase
          next unless title == q || title.include?(q)

          route = Pathfinder.route(@world, from: @world.position, to: edge.from, state: state)
          next if route.nil?

          cost = route.cost + Pathfinder.cost(edge)
          best = { edge: edge, route: route, cost: cost } if best.nil? || cost < best[:cost]
        end
        best
      end

      def best_route(matches, state)
        return [nil, nil] if matches.empty?

        best = nil
        matches.each do |room|
          r = Pathfinder.route(@world, from: @world.position, to: room.id, state: state)
          next if r.nil?
          best = [r, room.id] if best.nil? || r.cost < best[0].cost
        end
        best || [nil, matches.first.id]
      end

      private

      def status_note(edge)
        edge.status == :open || edge.status == :unknown ? "" : " [#{edge.status}]"
      end

      def expected_note(edge)
        edge.expected_title ? " (listed as #{edge.expected_title})" : ""
      end

      def frontier_note
        "#{@world.frontier_edges.size} unexplored exits remain."
      end
    end
  end
end
