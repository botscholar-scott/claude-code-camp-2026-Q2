require_relative "../primitives"
require_relative "parser"
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
      attr_reader :trail

      def initialize(runner:, world: nil, store: nil)
        @runner = runner
        @store  = store
        @world  = world || store&.load || World.new
        # Every move made this session, in order: the breadcrumbs. Not part of
        # the map and not persisted, because it describes what this process did
        # rather than what the world is.
        @trail = []
        # The route still to walk, front first. Handing the model a list of
        # thirty directions and asking it to keep its own place is asking it to
        # be a stack, and it is not one: it re-reads its own summary, miscounts,
        # and re-issues a move it already made. So the stack lives here. Give it
        # a route once; each move that lands is popped, and what is left is
        # reported back every time. Session state like @trail, not part of the
        # map, so it is not persisted.
        @plan = []
        # True while undoing the trail, so retracing does not extend it.
        @replaying = false
      end

      attr_reader :plan

      # ── the fold (§8.1) ─────────────────────────────────────────────────────

      # Every gameplay call the daemon executes passes through here. Live, the
      # server that runs the move has the direction and the result in the same
      # place, so nothing has to tail a log or correlate by position (§9.1).
      def observe(tool_name, args, result, ok: true)
        from = @world.position
        res  = Projection.apply(@world, tool_name, args, result, ok: ok)
        track(from, res)
        persist
        res
      end

      # The trail has to record EVERY observed move, not only the ones made
      # through a map tool. The agent is free to call `move` directly, and it
      # does; a trail that misses those describes a walk nobody took, and
      # map_back then finds itself somewhere the trail does not predict and
      # refuses to go anywhere. Tracking at the fold instead of in #step means
      # every path into the map keeps the breadcrumbs honest.
      def track(from, res)
        return if @replaying

        case res.outcome
        when :arrived, :arrived_dark
          dir = res.edge&.direction
          @trail << { from: from, direction: dir, to: res.room.id } if from && dir
        when :relocalized
          # `look` normally just confirms where we already were. `flee` lands us
          # somewhere unpredictable with no edge to undo, and a look that
          # identifies a different room means something moved us that we never
          # saw. Either way the breadcrumbs no longer lead home.
          @trail.clear if from && res.room && res.room.id != from
        when :lost
          @trail.clear
        end
      end

      # Moves made while undoing the trail must not extend it.
      def replaying
        prev, @replaying = @replaying, true
        yield
      ensure
        @replaying = prev
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

        return no_route(destination, matches) if route.nil?

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

      # Walk a route somebody has already worked out.
      #
      # map_goto searches the map for a destination it knows. There is a whole
      # other case it does not cover: the route is already known and came from
      # outside the map — a player typed it, a walkthrough gave it, the map on
      # another character has it. There is nothing to search for. All that is
      # left is to walk it.
      #
      # Without this the model has to emit one move call per direction, which
      # puts it back in the loop at every doorway and is exactly the 189:1 cost
      # §1 measured. Worse, it loses its place: a thirty-move route becomes
      # thirty chances to miscount, and it only takes one to end up somewhere
      # nobody can explain. One call, thirty moves, every arrival verified, and
      # a report saying precisely how far it got and what is left.
      # Passing directions loads the stack. Passing nothing resumes whatever is
      # still on it, which is what makes a route survive an interruption: get
      # blocked, deal with the mob, call map_follow again with no arguments and
      # carry on from the move you had reached.
      def follow(directions = nil, state: {})
        @plan = parse_directions(directions) if directions
        return "No route in progress. Give me one to follow." if @plan.empty?
        return "I do not know where I am. Call map_where first." if @world.position.nil?

        total  = @plan.size
        walked = []

        while (dir = @plan.first) && walked.size < MAX_STEPS
          res = step(dir)
          case res.outcome
          when :arrived, :arrived_dark
            @plan.shift              # popped only once it actually landed
            walked << dir
          when :refused
            return stopped(walked, total, "#{dir} is blocked (#{res.observation&.reason})")
          else
            return stopped(walked, total,
                           "the reply to #{dir} could not be read and looking did not settle it, " \
                           "so I do not know where I am")
          end
        end

        return "Followed #{walked.size} moves and arrived at #{@world.current&.title}. " \
               "Route complete." if @plan.empty?

        "Walked #{walked.size} of #{total} moves, now in #{@world.current&.title}. " \
          "#{@plan.size} still to go — call map_follow again with no directions to continue."
      end

      # Accepts "north west north", "n,w,n", or a list. Abbreviations are the
      # ones the game itself takes, so a route copied from anywhere works.
      def parse_directions(input)
        tokens = input.is_a?(Array) ? input : input.to_s.split(/[\s,]+/)
        tokens.filter_map do |t|
          t = t.to_s.strip.downcase
          World::DIRECTIONS.include?(t) ? t : Parser::ABBREV[t]
        end
      end

      # The unwalked remainder stays on the stack, so this is a pause, not a
      # loss. Say where we actually are and what is left, and say how to resume.
      def stopped(walked, total, why)
        "Stopped after #{walked.size} of #{total} moves (#{walked.join(',')}): #{why}. " \
          "You are in #{@world.current&.title || 'an unknown room'}. " \
          "#{@plan.size} moves still on the route: #{@plan.join(' ')}. " \
          "Clear the obstacle and call map_follow with no directions to carry on, " \
          "or pass new directions to replace the route."
      end

      # Expand the boundary. §6.7: the right choice is the unexplored exit
      # cheapest to reach from where you are now, not an arbitrary one — that
      # is what stops exploration ping-ponging across the map.
      # `count` walks several unexplored exits in one call, which is the whole
      # economy of this epic: N discoveries for one model round trip instead of
      # N. It stops early on anything it cannot classify.
      def explore(count: 1, state: {}, mode: "survey")
        n    = [[count.to_i, 1].max, MAX_STEPS].min
        outs = []
        n.times do
          out = mode.to_s == "dive" ? explore_once(state: state) : survey_once(state: state)
          outs << out
          break if out.start_with?("No unexplored", "I do not know", "Stopped")
          break if mode.to_s == "dive" && !out.start_with?("Explored")
        end
        outs.join("\n")
      end

      # ── survey: probe every exit of one room and come straight back ─────────
      #
      # Stand in A, and for each exit A has:
      #
      #   1. one `exits` call names every destination A can see (done on
      #      arrival, once per room ever)
      #   2. walk the exit — the arrival is what actually establishes where it
      #      goes, and whether the listing was telling the truth
      #   3. walk the inverse straight back. §6.7 forbids *inventing* the
      #      reverse edge, but nothing forbids walking one and watching. Landing
      #      back in A observes it; landing elsewhere, or being refused, is an
      #      observation too, and one that a map built by guessing would have
      #      got wrong.
      #   4. A exhausted: route to the nearest room that still has an untried
      #      exit and start again.
      #
      # Two moves per edge instead of one, and in exchange the map comes out
      # bidirectional wherever the world actually is, which is what makes
      # map_goto able to route home rather than only outward. Dive mode
      # (`mode: "dive"`) is the cheaper depth-first walk that does not come back.
      def survey_once(state: {})
        return "I do not know where I am. Call map_where first." if @world.position.nil?

        unless @world.edges_from(@world.position).any?(&:untried?)
          out = approach_untried(state)
          return out unless out.nil?
        end

        home  = @world.position
        lines = ["Surveying #{@world.room(home)&.title}:"]

        while (edge = frontier_here(state))
          lines << probe(edge, home)
          break unless @world.position == home
        end

        lines << frontier_note
        lines.join(" ")
      end

      # Get to somewhere with something left to try. Returns nil once we are
      # standing there, or a message explaining why we are not.
      def approach_untried(state)
        route, edge = Pathfinder.nearest_frontier(@world, from: @world.position, state: state)

        if edge.nil?
          # Nothing routable forward. Walk back down the trail instead — we know
          # the rooms we came through even when the map has no recorded way.
          out = retreat_to_untried
          return out unless out.nil?
          return nil
        end

        return nil if route.steps.empty?

        out = walk(route, "the nearest room with an unexplored exit")
        @world.position == edge.from ? nil : out
      end

      # One out-and-back. `home` is where we must end up for the round trip to
      # have proved anything.
      def probe(edge, home)
        res = step(edge.direction)
        case res.outcome
        when :refused
          return "#{edge.direction} is blocked (#{res.observation.reason});"
        when :arrived, :arrived_dark
          there = res.room
        else
          return "Stopped: #{edge.direction} gave a reply I could not read, position unknown."
        end

        reverse = World::REVERSE[edge.direction]
        # Whether the map already had this return edge decides only what we
        # report; we walk it either way, because a listing that omits south is
        # not evidence that south does not exist.
        knew = @world.edge(there.id, reverse)&.to
        home_again = step(reverse)

        case home_again.outcome
        when :arrived, :arrived_dark
          if home_again.room.id == home
            @trail.pop # the return
            @trail.pop # the outbound
            "#{edge.direction} -> #{there.title}#{knew ? '' : " (#{reverse} comes back)"};"
          else
            "Stopped: #{edge.direction} -> #{there.title}, but #{reverse} from there leads to " \
              "#{home_again.room.title}, not back here. Recorded — I am now in #{home_again.room.title}."
          end
        when :refused
          "Stopped: #{edge.direction} -> #{there.title}, and #{reverse} is not the way back " \
            "(#{home_again.observation.reason}). Recorded — I am still in #{there.title}."
        else
          "Stopped: #{edge.direction} -> #{there.title}, then an unreadable reply going #{reverse}. " \
            "Position unknown, call map_where."
        end
      end

      # Depth-first search, with the backtracking leg that makes it a search
      # rather than a one-way walk:
      #
      #   1. an untried exit right here?          take it
      #   2. an untried exit I can route to?      go there and take it
      #   3. neither?                             walk back the way I came until
      #                                           I reach a room that still has
      #                                           one, and take that
      #
      # Step 3 is the one that was missing. Step 2 can only use edges already
      # walked or destinations the game has named, and exploring produces
      # neither in the direction of home, so a dead end used to leave the search
      # with nothing at all to do. Retracing is always available, because we
      # know the rooms we came through.
      def explore_once(state: {})
        return "I do not know where I am. Call map_where first." if @world.position.nil?

        here = frontier_here(state)
        return take(here) if here

        route, edge = Pathfinder.nearest_frontier(@world, from: @world.position, state: state)
        if edge
          unless route.steps.empty?
            approach = walk(route, "the nearest unexplored exit")
            return approach unless @world.position == edge.from
          end
          return take(edge)
        end

        backtrack_to_untried(state)
      end

      # An untried exit leaving the room we are standing in.
      # Untried exits are not filtered by whether the search would route
      # *through* them. Routing through a shut door is refused because we have
      # no way to open it; trying it once is exactly how we find out what it
      # does. A plain unknown exit is preferred, and a door that comes back
      # refused records evidence and stops being untried.
      def frontier_here(_state)
        edges = @world.edges_from(@world.position).select(&:untried?)
        edges.find { |e| e.status == :unknown } || edges.first
      end

      # Nothing reachable forward. Retrace until we stand somewhere with an
      # exit nobody has tried, then try it. This is "move back to an earlier
      # location and test a different exit", and it is why exploring can no
      # longer strand itself.
      def backtrack_to_untried(state)
        out = retreat_to_untried
        return out unless out.nil?

        edge = frontier_here(state)
        return "Nothing untried here after all. #{frontier_note}" if edge.nil?

        "Backtracked to #{@world.current&.title}. #{take(edge)}"
      end

      # Walk back down the trail until we stand somewhere with an exit nobody
      # has tried. Returns nil once we are there, or a message saying why not.
      def retreat_to_untried
        depth = @trail.each_index.reverse_each.find do |i|
          @world.edges_from(@trail[i][:from]).any?(&:untried?)
        end

        if depth.nil?
          return "No unexplored exits left that I can reach, and nothing on my trail leads to " \
                 "one. #{frontier_note}"
        end

        out = back(steps: @trail.size - depth)
        return nil if @world.position && @world.edges_from(@world.position).any?(&:untried?)

        "#{out} Still nothing untried within reach. #{frontier_note}"
      end

      def take(edge)
        res = step(edge.direction)
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
            # A step that was only a lead — the game named the destination but
            # nobody had walked it — landing somewhere else is not a broken map,
            # it is the lead being tested and found wrong. Either way the truth
            # is now recorded.
            lead = st.presumed ? " That exit was listed as leading there but does not." : ""
            return "Stopped after #{taken.join(',')}: expected #{@world.room(st.to)&.title} " \
                   "but arrived in #{res.room.title}.#{lead} The map now records what is " \
                   "actually there. Re-run map_goto to continue."
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
        from = @world.position
        res  = observe("move", { "direction" => direction }, @runner.call(P.move(direction)))
        res  = settle(direction, from, res) if res.outcome == :lost

        # Ask the game where this room's exits go, the moment we arrive in one
        # nobody has asked about. Never assume: `exits` will state outright
        # whether there is a way south and where it leads, or say nothing about
        # south at all, and either answer beats inferring one.
        #
        # This used to run only inside map_where and map_explore, so a room
        # entered any other way kept its exits unnamed. That is how the agent
        # ended up stranded: it walked into a room with no listing and no walked
        # exit out, and the search had literally nothing to work with.
        #
        # One MUD round trip, once per room ever, guarded by listed_seq.
        label_exits if needs_exit_listing?(res.room)
        res
      end

      # A move reply the parser could not classify is not a mystery. It is a
      # question with a cheap and completely general answer: look, and see where
      # you are.
      #
      #   same room as before -> the move was refused
      #   a different room    -> the move worked
      #
      # That is an observation, and it needs to know nothing about what this
      # particular server says when it turns you down. The alternative is a
      # table of English phrases, and measured against this corpus that table
      # got 9 of the 14 non-arrival replies wrong even on the MUD it was written
      # for — "You are too exhausted.", "This zone is above your recommended
      # level.", "Maybe you should get on your feet first?", "No way!  You're
      # fighting for your life!" — none of which any list would have predicted,
      # and each of which cost a lost position.
      #
      # Cost is one extra round trip on a failed move: 14 of them across the
      # whole corpus. The reason for the refusal stays unknown, and routing does
      # not need it — `blocked` is impassable regardless of why.
      def settle(direction, from, res)
        return res if from.nil?

        look = observe("look", {}, @runner.call(P.look))
        return res unless look.outcome == :relocalized && look.room

        seq = @world.next_seq
        if look.room.id == from
          edge = @world.record_edge(from: from, direction: direction, to: nil,
                                    status: :blocked, seq: seq)
          Projection::Result.new(observation: res.observation, outcome: :refused,
                                 room: look.room, edge: edge)
        else
          edge = @world.record_edge(from: from, direction: direction, to: look.room.id,
                                    status: :open, seq: seq)
          Projection::Result.new(observation: res.observation, outcome: :arrived,
                                 room: look.room, edge: edge)
        end
      end

      # Retrace the way you came.
      #
      # This is the only honest way to learn the edges home. The map records
      # only the direction actually walked, because a north from A to B does not
      # prove a south from B to A — MUDs have one-way exits. So exploration
      # leaves a trail of arrows all pointing outward and no recorded way back.
      #
      # Walking it in reverse is a hypothesis, and every step tests it: we know
      # exactly which room each step should land in, because we were standing in
      # it a moment ago. A step that lands where predicted has just *observed*
      # the reverse edge, and the ordinary projection records it as a real
      # traversal. A step that does not stops the whole thing, because from
      # there on we no longer know where we are.
      #
      # After a round trip the map is two-way along that path, and map_goto
      # works over it forever after.
      def back(steps: nil, state: {})
        return "No moves recorded this session, so there is nothing to retrace." if @trail.empty?

        wanted = steps ? [steps.to_i, @trail.size].min : @trail.size
        return "Nothing to retrace." if wanted <= 0

        target = @trail[@trail.size - wanted][:from]
        return "You are already there." if target == @world.position

        # 1. Does the map already know a way? Then going back is just
        #    navigation, and Dijkstra picks the shortest one — which is often
        #    NOT the path we came by, because exploring wanders and the map has
        #    since learned shortcuts. Every walked edge and every destination
        #    the game named is fair game.
        route = Pathfinder.route(@world, from: @world.position, to: target, state: state)
        if route && !route.steps.empty?
          out = replaying { walk(route, @world.room(target)&.title.to_s) }
          if @world.position == target
            @trail.slice!(@trail.size - wanted, wanted)
            return "#{out} (routed by the map, not by retracing)"
          end
          return out
        end

        # 2. The map does not know a way, so fall back to the one hypothesis we
        #    have: the reverse of each move we made. It is only a hypothesis,
        #    since one-way exits are real, so every step is checked against the
        #    room it should land in. A step that confirms has just observed a
        #    return edge and the projection records it, which is how the map
        #    stops being one-way and how case 1 gets to win next time.
        retrace(wanted, state)
      end

      def retrace(wanted, state)
        taken   = []
        learned = 0

        wanted.times do
          entry   = @trail.last
          reverse = World::REVERSE[entry[:direction]]

          # Breadcrumbs that disagree with where we are are worse than none: the
          # same call would fail the same way forever. Drop them and say so, so
          # the next call is a fresh question rather than a repeat of this one.
          if @world.position != entry[:to]
            @trail.clear
            return "Stopped after #{summary(taken)}: I am not where my breadcrumbs say I should " \
                   "be, so I have dropped them. Call map_where, then map_goto with a room name — " \
                   "the map itself is unaffected."
          end

          # Prefer a known route for this single hop too, if one has appeared.
          hop = Pathfinder.route(@world, from: entry[:to], to: entry[:from], state: state)
          if hop && !hop.steps.empty? && hop.steps.none? { |s| s.direction == reverse }
            out = replaying { walk(hop, @world.room(entry[:from])&.title.to_s) }
            return "Stopped after #{summary(taken)}: #{out}" unless @world.position == entry[:from]
            taken.concat(hop.directions)
            @trail.pop
            next
          end

          already = @world.edge(entry[:to], reverse)&.to
          res     = replaying { step(reverse) }

          case res.outcome
          when :arrived, :arrived_dark
            if res.room.id != entry[:from]
              return "Stopped after #{summary(taken)}: going #{reverse} from " \
                     "#{@world.room(entry[:to])&.title} should have returned me to " \
                     "#{@world.room(entry[:from])&.title} but I arrived in #{res.room.title}. " \
                     "That exit is not the way back, and the map now records where it does go."
            end
            learned += 1 if already.nil?
            taken << reverse
            @trail.pop
          when :refused
            return "Stopped after #{summary(taken)}: #{reverse} is blocked " \
                   "(#{res.observation.reason}), so it is not the way back. Marked on the map."
          else
            return "Stopped after #{summary(taken)}: unrecognised reply going #{reverse}. " \
                   "Position unknown, call map_where."
          end
        end

        where = @world.current&.title
        note  = learned.positive? ? " Learned #{learned} return route(s) the map did not have." : ""
        "Backtracked #{taken.size} move(s) to #{where}: #{taken.join(',')}.#{note}"
      end

      # ── lookup ──────────────────────────────────────────────────────────────

      # Titles are clean and they repeat: "Main Street" covers three physically
      # distinct rooms (§6.2). So a name is a filter, not a key, and the search
      # returns every match and lets the router pick the nearest.
      # Nobody types a room's title. They type what they remember of it. A plain
      # substring match cannot survive that: "guild of the swordsman" does not
      # occur inside "The Entrance Hall To The Guild Of Swordsmen", because of
      # one stray "the" and one irregular plural. That exact miss sent the agent
      # off exploring for a room it was already holding a route to, and it died
      # in the sewers looking for it.
      #
      # So: compare word by word, ignore the joining words nobody means, and let
      # a word match its near-neighbour. Ranked, because a real title match
      # should always beat a loose one.
      JOINERS = %w[the a an of to at in on and].freeze

      def search(query)
        q = query.to_s.strip.downcase
        return [] if q.empty?

        rooms = @world.rooms.values.reject(&:dark?)
        wanted = words(q)

        exact = rooms.select { |r| r.title.downcase == q }
        return exact unless exact.empty?

        substring = rooms.select { |r| r.title.downcase.include?(q) }
        return substring unless substring.empty?
        return [] if wanted.empty?

        rooms.select do |r|
          have = words(r.title)
          wanted.all? { |w| have.any? { |h| akin?(w, h) } }
        end
      end

      def words(str) = str.downcase.scan(/[a-z0-9]+/) - JOINERS

      # Two words mean the same thing closely enough to route on. Either one
      # leads the other ("sword" for "swordsmen"), or they agree on everything
      # but their ending, which is what separates a plural, a possessive or a
      # typo from a different word. Deliberately generous: the caller gets every
      # candidate and routes to the nearest, so a stray extra match costs
      # nothing while a miss costs a death in the sewers.
      def akin?(a, b)
        return true if a == b
        return true if a.size >= 4 && b.start_with?(a)
        return true if b.size >= 4 && a.start_with?(b)

        shared = 0
        shared += 1 while shared < a.size && shared < b.size && a[shared] == b[shared]
        shared >= 4 && (a.size - b.size).abs <= 2 && shared >= [a.size, b.size].min - 2
      end

      # The cheapest unwalked exit whose listed destination matches the query:
      # the cost of reaching the room it leaves from, plus the step itself.
      # The old message here blamed "blocked edges", which was almost never the
      # reason and told the agent nothing it could act on. The real reason is
      # nearly always that the map records only the way out, not the way home:
      # exploration walks outward, and a north from A to B is not evidence of a
      # south from B to A, so the arrows all point away from where you started.
      # Say that, and name the tool that fixes it.
      def no_route(destination, matches)
        blocked = @world.edges.values.any? { |e| %i[closed_door blocked_by_mob needs_item].include?(e.status) }
        msg = +"I know #{matches.size} room(s) matching #{destination.inspect}, but nothing I have " \
               "walked leads there from here."
        msg << " I have not recorded a way back out of this room yet." if @world.edges_from(@world.position).none?(&:to)
        msg << " Some edges are blocked, which may be part of it." if blocked
        msg << " Try map_back to retrace the way you came, which also teaches the map the return routes, " \
               "or map_explore to keep expanding."
        msg
      end

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

      def summary(taken) = taken.empty? ? "no moves" : taken.join(",")

      def frontier_note
        "#{@world.frontier_edges.size} unexplored exits remain."
      end
    end
  end
end
