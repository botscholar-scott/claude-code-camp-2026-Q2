require_relative "parser"
require_relative "world"

module MudManager
  module Map
    # Projection is the one function that updates the map:
    #
    #   (world, tool_name, args, result) -> world
    #
    # Live, it is fed one observation at a time by the Dispatcher, which has
    # the direction and the result in the same call. For development it can be
    # fed a recorded session instead — the same function in a loop (§8.1).
    # That is what makes the corpus useful without making it authoritative: the
    # map is a stored artifact, not something derived from session logs (§6.1).
    #
    # It is "pure" in the sense that matters here: no I/O, no clock, no
    # randomness beyond room ids, and the whole of its effect is on the World
    # handed to it.
    module Projection
      Result = Struct.new(:observation, :outcome, :room, :edge, keyword_init: true)

      # outcome:
      #   :arrived      moved and identified the room
      #   :arrived_dark moved, room unidentifiable, position dead-reckoned
      #   :relocalized  a look told us where we are without moving
      #   :refused      the MUD declined; position unchanged, edge annotated
      #   :lost         unrecognised reply; position cleared, must re-localize
      #   :labelled     the `exits` listing named this room's neighbours
      #   :ignored      not an observation at all
      OUTCOMES = %i[arrived arrived_dark relocalized refused lost labelled ignored].freeze

      module_function

      # `ok:` is the MCP-level success flag F34 bought. Per §7.1 it is NOT a
      # blocked-move sensor — a closed door is an ordinary round-trip that
      # succeeded. All it means here is "this call is not an observation".
      def apply(world, tool_name, args, result, ok: true)
        return ignored(nil) unless ok

        verb = base_name(tool_name)
        args = args || {}

        case verb
        when "move"     then apply_move(world, args["direction"], result)
        when "look"     then apply_look(world, args, result)
        when "check"    then apply_check(world, args, result)
        when "flee"     then apply_displacement(world, result)
        when "send_raw" then apply_raw(world, args["command"], result)
        else ignored(nil)
        end
      end

      # The `exits` command names the room on the other side of every visible
      # exit, without moving. `look` gives the direction set; this gives the
      # direction set plus destinations, so one call labels up to six edges
      # that would otherwise each cost a walk to discover.
      #
      # It mints nothing. A title is not a room key (§6.2), so what is learned
      # is a property of the EDGE, and identity is still settled on arrival by
      # hashing (title, description).
      def apply_check(world, args, result)
        return ignored(nil) unless args["kind"].to_s == "exits"

        obs = Parser.parse(result)
        return ignored(obs) unless obs.exit_list?
        return ignored(obs) if world.position.nil?

        seq  = world.next_seq
        room = world.current
        obs.destinations.each do |abbrev, title|
          dir = Parser::ABBREV[abbrev] || abbrev
          world.record_expected(from: room.id, direction: dir, title: title, seq: seq)
        end
        world.mark_exits_listed(room, seq)
        Result.new(observation: obs, outcome: :labelled, room: room)
      end

      # send_raw is the escape hatch for when no structured tool fits, and an
      # agent can move with it. An unobserved move desyncs `position`, which
      # then routes confidently from the wrong room.
      #
      # Only a bare direction or a bare look is folded in. Anything else is
      # ignored on purpose: `look north` peeks into the *adjacent* room and
      # returns a full room block, so a projection that accepted any room block
      # off the raw channel would teleport the map into the room next door.
      def apply_raw(world, command, result)
        cmd = command.to_s.strip.downcase
        dir = World::DIRECTIONS.find { |d| d == cmd } || Parser::ABBREV[cmd]
        return apply_move(world, dir, result) if dir
        return apply_look(world, {}, result)  if %w[look l].include?(cmd)
        return apply_check(world, { "kind" => "exits" }, result) if %w[exit exits].include?(cmd)
        ignored(nil)
      end

      # ── move ────────────────────────────────────────────────────────────────

      def apply_move(world, direction, result)
        direction = World::DIRECTIONS.find { |d| d == direction.to_s } ||
                    Parser::ABBREV[direction.to_s.downcase]
        return ignored(nil) unless direction

        obs   = Parser.parse(result)
        from  = world.position
        seq   = world.next_seq
        prior = from ? world.edge(from, direction) : nil

        case obs.kind
        when :room
          coords = world.coords_for(from, direction) || [0, 0, 0]
          room   = world.observe_room(obs, seq: seq, coords: coords)
          # We have walked this edge before and it led somewhere we could not
          # identify at the time. Now we can. Fold the placeholder in rather
          # than letting the map carry two nodes for one room.
          world.absorb(prior.to, room.id) if prior&.to && prior.to != room.id && world.room(prior.to)&.dark?
          # An `exits` listing said what was through here. Walking it is the
          # observation that settles the label, so a disagreement is a real
          # contradiction rather than a stale guess.
          world.check_expectation(prior, room, seq) if prior&.expected_title
          world.record_announced_exits(room, seq: seq)
          edge = from ? world.record_edge(from: from, direction: direction, to: room.id,
                                          status: :open, seq: seq) : nil
          world.position = room.id
          Result.new(observation: obs, outcome: :arrived, room: room, edge: edge)

        when :dark
          # §5: pitch black means the move SUCCEEDED and the room cannot
          # identify itself. Treating it as a failure would corrupt position.
          # Identity falls back to movement history where we have it — this
          # edge has a known destination — and to dead reckoning where we
          # do not.
          coords = world.coords_for(from, direction) || [0, 0, 0]
          room   = (prior&.to && world.touch_room(prior.to, seq)) ||
                   world.observe_dark(seq: seq, coords: coords)
          edge = from ? world.record_edge(from: from, direction: direction, to: room.id,
                                          status: :open, seq: seq) : nil
          world.position = room.id
          Result.new(observation: obs, outcome: :arrived_dark, room: room, edge: edge)

        when :refused
          # Position is unchanged. Annotate the edge so the pathfinder routes
          # around it with no planner involved (§8 step 2).
          edge = nil
          if from
            edge = world.record_edge(from: from, direction: direction, to: nil,
                                     status: status_for(obs), seq: seq,
                                     requires: requires_for(obs))
          end
          Result.new(observation: obs, outcome: :refused, room: world.current, edge: edge)

        else
          # §5.1: the parser must not assume it has seen the whole failure
          # taxonomy. An unrecognised reply is "position unknown, re-localize",
          # never a successful move.
          world.position = nil
          Result.new(observation: obs, outcome: :lost)
        end
      end

      # ── look ────────────────────────────────────────────────────────────────

      # Re-localization is one `look` (§6.2), which is what makes a map built
      # yesterday usable today. A look at a *target* tells us nothing about
      # where we are, so it is not an observation.
      def apply_look(world, args, result)
        return ignored(nil) unless blank?(args["target"])
        prep = args["preposition"].to_s
        return ignored(nil) unless blank?(prep) || prep == "at"

        obs = Parser.parse(result)
        return Result.new(observation: obs, outcome: :ignored) unless obs.room?

        seq  = world.next_seq
        room = world.observe_room(obs, seq: seq, coords: world.current&.coords || [0, 0, 0])
        world.record_announced_exits(room, seq: seq)
        world.position = room.id
        Result.new(observation: obs, outcome: :relocalized, room: room)
      end

      # `flee` moves you somewhere unpredictable. The room is identifiable but
      # the edge is not, so record the arrival and record no traversal.
      def apply_displacement(world, result)
        obs = Parser.parse(result)
        return lost(world, obs) unless obs.room?

        seq  = world.next_seq
        room = world.observe_room(obs, seq: seq, coords: world.current&.coords || [0, 0, 0])
        world.record_announced_exits(room, seq: seq)
        world.position = room.id
        Result.new(observation: obs, outcome: :relocalized, room: room)
      end

      # ── helpers ─────────────────────────────────────────────────────────────

      def status_for(obs)
        case obs.reason
        when :closed_door    then :closed_door
        when :needs_boat     then :needs_item
        when :blocked_by_mob then :blocked_by_mob
        when :no_exit        then :no_exit
        else :unknown
        end
      end

      def requires_for(obs)
        obs.reason == :needs_boat ? ["boat"] : nil
      end

      def lost(world, obs)
        world.position = nil
        Result.new(observation: obs, outcome: :lost)
      end

      def ignored(obs) = Result.new(observation: obs, outcome: :ignored)

      def blank?(v) = v.nil? || v.to_s.strip.empty?

      # Tool names reach us prefixed by whatever the MCP client calls the
      # server ("tbamud__move"), or bare ("move") over the raw protocol.
      def base_name(name) = name.to_s.split("__").last.to_s
    end
  end
end
