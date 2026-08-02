require_relative "helper"
require_relative "map_fixtures"
require "tmpdir"

# §9.1 — the map belongs in the MCP server. ADR 0012 is unambiguous: boukensha
# ships no tools and every capability comes from an MCP server, so "take me to
# the bakery" has to be an MCP tool. This server also already executes the
# move, so the direction and the result are in the same call.
class TestMapTools < Minitest::Test
  M = MudManager::Map
  F = MapFixtures

  # A three-room strip of Midgaard the runner walks over, so the tools can be
  # driven with no MUD and no telnet:
  #
  #   Common Square --n-- Market Square --n-- Temple Square --w-- Reading Room
  #
  # Every connection here is a direction the room's own fixture announces, so
  # walking the strip never trips the degree invariant. The Reading Room's west
  # is its shut door and leads nowhere.
  WORLD = {
    "The Common Square" => { "north" => "Market Square" },
    "Market Square"     => { "north" => "The Temple Square", "south" => "The Common Square" },
    "The Temple Square" => { "south" => "Market Square", "west" => "The Reading Room" },
    "The Reading Room"  => { "south" => "The Temple Square" }
  }.freeze

  TEXT = {
    "The Common Square" => F::COMMON_SQUARE,
    "Market Square"     => F::MARKET_SQUARE,
    "The Temple Square" => F::TEMPLE_SQUARE,
    "The Reading Room"  => F::DOORED_ROOM
  }.freeze

  # Stands in for SessionPool: walks the little world above and returns the
  # screen text tbaMUD would have sent.
  class FakeWorldRunner
    attr_reader :sent, :here

    def initialize(start, graph, text, overrides = {})
      @here, @graph, @text, @overrides = start, graph, text, overrides
      @sent = []
    end

    def call(command)
      @sent << command.raw
      case command.primitive
      when :move      then walk(command.verb)
      when :look      then @text.fetch(@here)
      when :info_self then command.verb == "exits" ? exit_listing : "Ok."
      else "Ok."
      end
    end

    # What the `exits` command returns: every visible exit WITH the name of the
    # room behind it, uncoloured. This is the information `look` does not give.
    def exit_listing
      rows = @graph.fetch(@here).map { |dir, dest| "#{dir.ljust(5)} - #{dest}\r" }
      (["Obvious exits:\r"] + rows + ["\r", "25H 100M 80V > "]).join("\n")
    end

    def walk(direction)
      if (canned = @overrides.delete([@here, direction]))
        return canned
      end
      dest = @graph.fetch(@here)[direction]
      return "Alas, you cannot go that way.\r\n\r\n25H 100M 80V > " if dest.nil?
      @here = dest
      @text.fetch(dest)
    end
  end

  def carto(start: "The Common Square", overrides: {}, world: nil)
    @runner = FakeWorldRunner.new(start, WORLD, TEXT, overrides)
    M::Cartographer.new(runner: @runner, world: world)
  end

  # Walk the strip out and back so the map knows it in both directions, then
  # hand the map back. Out-and-back matters: §6.7 forbids inventing the reverse
  # edge, so a route home only exists if it was actually walked.
  def walk_the_strip(c)
    c.where
    %w[north north west south south south].each { |d| c.step(d) }
    c
  end

  def explored_world = walk_the_strip(carto).world

  # One `look` to find out where we are, then one `exits` to find out what is
  # around us. Both are MUD round trips inside a single tool call, which is the
  # trade that matters: §1's cost was model round trips, not MUD ones.
  def test_map_where_relocalizes_and_labels_the_exits
    c = carto
    out = c.where

    assert_equal %w[look exits], @runner.sent
    assert_includes out, "The Common Square"
    assert_includes out, "Unexplored exits"
  end

  # The names come from the `exits` listing, so an exit nobody has walked still
  # says where it goes.
  def test_map_where_names_rooms_behind_exits_never_walked
    c = carto
    out = c.where

    assert_includes out, "north (listed as Market Square)"
    refute_equal "Market Square", c.world.current.title, "and we have not gone there"
    assert_equal 1, c.world.room_count, "naming a destination mints nothing"
  end

  # Asking twice costs nothing: once every exit is labelled or walked there is
  # no reason to run the listing again.
  def test_the_exits_listing_is_not_repeated_once_everything_is_labelled
    c = carto
    c.where
    @runner.sent.clear
    c.where

    assert_equal ["look"], @runner.sent
  end

  def test_map_where_names_the_rooms_behind_known_exits
    world = explored_world
    c = carto(start: "The Common Square", world: world)
    out = c.where

    assert_includes out, "north -> Market Square"
  end

  # §1 — this is the whole point. One call replaces one model round-trip per
  # step through a doorway.
  def test_map_goto_walks_the_whole_route_in_one_call
    world = explored_world
    c = carto(start: "The Common Square", world: world)
    c.where
    out = c.goto("temple")

    assert_includes out, "Arrived at The Temple Square"
    assert_includes out, "north,north"
    assert_equal "The Temple Square", @runner.here
  end

  def test_map_goto_reports_an_unknown_destination_rather_than_wandering
    c = carto(world: explored_world)
    c.where
    @runner.sent.clear

    out = c.goto("the bakery")
    assert_includes out, "Nothing I have seen or been told about"
    assert_empty @runner.sent, "it does not guess directions"
  end

  # The point of the `exits` listing: a room we were told about but have never
  # stood in is a real destination, reached by routing to the doorway and
  # taking it.
  def test_map_goto_reaches_a_room_named_but_never_visited
    c = carto(start: "The Common Square")
    c.where   # look + exits: learns that north is Market Square

    refute c.world.rooms.values.any? { |r| r.title == "Market Square" },
           "we have only been told the name, never been there"

    out = c.goto("market square")
    assert_includes out, "Arrived at Market Square"
    assert_includes out, "never visited before"
    assert_equal "Market Square", @runner.here
  end

  # A listed name is a label on the edge, and walking it is what settles it.
  # If the two disagree, and the label names a room we have actually stood in,
  # that is a contradiction between two of our own observations rather than a
  # silent overwrite. Starting in Market Square is what makes that name a room
  # we know rather than an unresolved label.
  def test_walking_an_exit_that_was_listed_wrongly_raises_a_contradiction
    c = carto(start: "Market Square",
              overrides: { ["The Common Square", "north"] => F::TEMPLE_SQUARE })
    c.where
    c.step("south")                    # into The Common Square, whose north is listed as Market Square
    c.step("north")                    # but the override lands us somewhere else

    assert_equal "The Temple Square", c.world.current.title
    assert_equal 1, c.world.violations.size
    assert_equal "destination_conflict", c.world.violations.first["kind"]
  end

  def test_map_goto_is_a_no_op_when_you_are_already_there
    c = carto(world: explored_world)
    c.where
    assert_includes c.goto("common square"), "already in"
  end

  # §6.7 — execution needs verification, not faith. A map-follower that assumes
  # its own moves worked is F34 all over again, one layer up.
  def test_a_route_that_does_not_land_where_predicted_stops_and_says_so
    world = explored_world
    # The map says Market Square is north of Common Square. Make the game
    # disagree, as it would if the character had been moved or the map is stale.
    c = carto(start: "The Common Square", world: world,
              overrides: { ["The Common Square", "north"] => F::CELLAR })
    c.where
    out = c.goto("temple")

    assert_includes out, "Stopped"
    assert_includes out, "A Dusty Cellar"
    assert_equal "A Dusty Cellar", c.world.current.title, "and the map now records the truth"
  end

  # §8 step 2 — the failure teaches the map, and the next route avoids it.
  def test_a_blocked_step_marks_the_edge_and_stops
    world = explored_world
    c = carto(start: "Market Square", world: world,
              overrides: { ["Market Square", "north"] => F::CLOSED_DOOR })
    c.where
    out = c.goto("temple")

    assert_includes out, "Stopped"
    assert_includes out, "closed_door"

    here = c.world.position
    assert_equal :closed_door, c.world.edge(here, "north").status
    assert_nil M::Pathfinder.route(c.world, from: here, to: c.world.rooms.values.find { |r| r.title == "The Temple Square" }.id),
               "the pathfinder now routes around it, and there is no other way"
  end

  # §6.7 — the right choice is the unexplored exit cheapest to reach from where
  # you are now, which is what stops exploration ping-ponging across the map.
  def test_map_explore_takes_the_nearest_untried_exit
    c = carto
    c.where
    _, chosen = M::Pathfinder.nearest_frontier(c.world, from: c.world.position)
    out = c.explore(mode: "dive")

    assert_includes out, "Explored"
    refute c.world.edge(chosen.from, chosen.direction).frontier?,
           "the exit it picked is no longer untried"
    assert_operator c.world.room_count, :>=, 2
  end

  # The survey: ask where the exits go, walk each one, walk straight back. The
  # round trip is what turns a hypothesis about the inverse into an observation
  # of it, and it is why the map comes out two-way.
  def test_surveying_probes_every_exit_and_comes_back
    c = carto
    c.where
    home = c.world.position
    out  = c.explore

    assert_includes out, "Surveying The Common Square"
    assert_equal home, c.world.position, "a survey ends where it began"

    north = c.world.edge(home, "north")
    assert_equal "Market Square", c.world.room(north.to).title
    assert_equal home, c.world.edge(north.to, "south")&.to,
                 "the way back was walked, not inferred from the way out"
    assert_empty c.world.edges_from(home).select(&:untried?),
                 "and every exit this room has was tried, including the ones that go nowhere"
  end

  # The point of paying two moves per edge: from the far end of the map there
  # is a route home made entirely of edges somebody actually walked.
  def test_surveying_leaves_a_walked_route_home_from_everywhere
    c = carto(world: M::World.new)
    c.where
    home = c.world.position
    40.times { break if c.world.frontier_edges.empty?; c.explore }

    c.world.rooms.each_value do |room|
      next if room.id == home
      refute_nil M::Pathfinder.route(c.world, from: room.id, to: home, presume: false),
                 "#{room.title} has no walked route back to the start"
    end
  end

  # "You can type exits after going A -> north -> B and it will absolutely tell
  # you you could go south, or it will not. Never assume anything." So the
  # survey walks the inverse regardless of what the listing said, and records
  # whatever actually happened — here, that there is no way back.
  def test_a_reverse_that_does_not_come_back_is_recorded_not_assumed
    one_way = {
      "The Common Square" => { "north" => "Market Square" },
      "Market Square"     => { "north" => "The Temple Square" },
      "The Temple Square" => {},
      "The Reading Room"  => {}
    }
    c = M::Cartographer.new(runner: FakeWorldRunner.new("The Common Square", one_way, TEXT))
    c.where
    home = c.world.position
    out  = c.explore

    assert_includes out, "north -> Market Square"
    assert_includes out, "not the way back"
    refute_equal home, c.world.position, "there is no way back, so we are still up there"

    market = c.world.rooms.values.find { |r| r.title == "Market Square" }
    south  = c.world.edge(market.id, "south")
    refute_nil south, "the inverse was tried, so there is an observation about it"
    assert_nil south.to, "and it is recorded as going nowhere rather than as going home"
  end

  # The agent mixes map tools and plain `move` calls freely, and it always
  # will. The trail used to be appended only inside Cartographer#step, so a
  # direct move left no breadcrumb; map_back then found itself somewhere the
  # trail did not predict and refused to move, every time, forever. Tracking at
  # the fold is what makes a direct move count.
  def test_map_back_undoes_moves_made_outside_the_map_tools
    c = carto
    c.where
    home = c.world.position

    # Exactly what tbamud__move does: straight through the fold, no map tool.
    c.observe("move", { "direction" => "north" }, @runner.call(MudManager::Primitives.move("north")))
    c.observe("move", { "direction" => "north" }, @runner.call(MudManager::Primitives.move("north")))

    refute_equal home, c.world.position
    out = c.back

    refute_includes out, "breadcrumbs"
    assert_equal home, c.world.position, "map_back undoes moves it did not make itself"
  end

  # A flee lands you somewhere unpredictable with no edge to undo, so the
  # breadcrumbs stop leading home and must not be walked as though they did.
  def test_being_displaced_drops_the_trail_rather_than_lying_about_it
    c = carto
    c.where
    c.step("north")
    refute_empty c.trail

    c.observe("flee", {}, F::TEMPLE_SQUARE)
    assert_empty c.trail, "there is no edge to undo, so there is no way back to retrace"
    assert_includes c.back, "nothing to retrace"
  end

  # A refusal in wording nothing here has ever seen. Measured on the corpus
  # this is the common case, not the exotic one: 9 of the 14 non-arrival move
  # replies were phrased in ways no pattern list anticipated. The map settles it
  # by looking rather than by matching, so the position survives and the edge is
  # marked.
  def test_a_refusal_in_unknown_wording_is_settled_by_looking
    c = carto(start: "The Common Square",
              overrides: { ["The Common Square", "north"] =>
                           "You are too exhausted.\r\n\r\n25H 100M 0V > " })
    c.where
    home = c.world.position

    res = c.step("north")

    assert_equal :refused, res.outcome
    assert_equal home, c.world.position, "we never moved, and the map still knows where we are"
    assert_equal :blocked, c.world.edge(home, "north").status
    assert_nil M::Pathfinder.route(c.world, from: home, to: home, state: {})&.steps&.first,
               "and nothing routes through it"
  end

  # The other half of the same question. A reply we cannot read might mean the
  # move WORKED, and assuming it did not would be just as wrong. The look tells
  # us which, and the traversal is recorded as the ordinary observation it is.
  def test_an_unreadable_reply_that_did_move_us_is_settled_the_same_way
    runner = Class.new do
      attr_reader :here
      def initialize(text) = (@here = "The Common Square"; @text = text; @moved = false)
      def call(command)
        case command.primitive
        when :move then (@moved = true; "The gods whisk you away.\r\n\r\n25H 100M 79V > ")
        when :look then @text.fetch(@moved ? "Market Square" : "The Common Square")
        else "Ok."
        end
      end
    end.new(TEXT)

    c = M::Cartographer.new(runner: runner)
    c.where
    home = c.world.position

    res = c.step("north")

    assert_equal :arrived, res.outcome
    assert_equal "Market Square", c.world.current.title
    assert_equal c.world.position, c.world.edge(home, "north").to,
                 "the traversal is on the map exactly as if we had read the reply"
  end

  # A route handed in from outside. There is nothing to search for, so the only
  # job is to walk it, and walking it must not cost one model round trip per
  # doorway — that is the failure mode this whole epic exists to kill.
  def test_map_follow_walks_a_given_route_in_one_call
    c = carto
    c.where
    out = c.follow("north north west")

    assert_equal "The Reading Room", c.world.current.title
    assert_includes out, "Followed 3 moves"
    assert_includes out, "The Reading Room"
  end

  def test_map_follow_takes_abbreviations_and_commas
    c = carto
    c.where
    c.follow("n, n, w")

    assert_equal "The Reading Room", c.world.current.title
  end

  # Stopping is the important half. A route from outside can be wrong, or the
  # world can have changed, and the answer is to say where you actually are and
  # exactly what is left rather than to plough on.
  def test_map_follow_stops_on_a_refusal_and_reports_what_remains
    c = carto
    c.where
    out = c.follow("north east north west")   # Market Square has no east exit

    assert_equal "Market Square", c.world.current.title
    assert_includes out, "Stopped after 1 of 4 moves"
    assert_includes out, "east north west", "what is left is reported back"
    assert_equal %w[east north west], c.plan, "and stays on the stack rather than being lost"
  end

  # The stack is the point. A route survives being interrupted: deal with
  # whatever stopped you, then resume with no arguments and it picks up at the
  # move it had reached rather than at the beginning.
  def test_an_interrupted_route_resumes_where_it_left_off
    c = carto(overrides: { ["Market Square", "north"] => F::UNKNOWN_REPLY })
    c.where
    c.follow("north north west")

    assert_equal "Market Square", c.world.current.title, "the second move failed"
    assert_equal %w[north west], c.plan

    c.follow                                   # no directions: resume
    assert_equal "The Reading Room", c.world.current.title
    assert_empty c.plan, "and the stack is empty once the route is done"
  end

  # Nobody types a room's exact title. The live failure that motivated this:
  # "guild of the swordsman" found nothing, because the room is called "The
  # Entrance Hall To The Guild Of Swordsmen" and a substring match cannot get
  # past one stray "the" and one irregular plural. The agent then went looking
  # for a room it already had a route to, and died in the sewers.
  def test_a_room_is_found_by_what_someone_would_actually_type
    c = carto(world: explored_world)

    ["the reading room", "reading room", "Reading Room", "reading rooms", "room reading"]
      .each { |q| assert_equal ["The Reading Room"], c.search(q).map(&:title), q.inspect }
  end

  def test_joining_words_and_plurals_do_not_defeat_the_search
    c = carto(world: explored_world)

    # "of the" is noise, and singular/plural must not matter.
    assert_equal ["Market Square"], c.search("the market squares").map(&:title)
    assert_equal ["The Common Square"], c.search("common of the square").map(&:title)
  end

  def test_a_name_that_matches_nothing_is_still_reported_as_nothing
    c = carto(world: explored_world)

    assert_empty c.search("bakery")
    assert_includes c.goto("bakery"), "Nothing I have seen"
  end

  # The property that matters is coverage, not the wording: exploring on its
  # own should eventually find every room, backtracking when it dead-ends,
  # rather than stalling the moment it runs out of forward moves.
  def test_exploring_alone_discovers_the_whole_world
    c = carto(world: M::World.new)
    c.where
    40.times { break if c.world.frontier_edges.empty?; c.explore }

    found = c.world.rooms.values.map(&:title).sort
    assert_equal WORLD.keys.sort, found,
                 "depth-first exploration with backtracking should reach every room"
  end

  def test_exploring_an_exhausted_map_says_so_rather_than_flailing
    c = carto(world: M::World.new)
    c.where
    40.times { break if c.world.frontier_edges.empty?; c.explore }

    out = c.explore
    assert_includes out, "No unexplored exits"
    assert_empty c.world.frontier_edges
  end

  # §6.1 — play for fifty hours, map the city, come back tomorrow, and it
  # already knows the way to the bakery.
  def test_the_map_survives_a_restart_and_routes_immediately
    Dir.mktmpdir do |dir|
      path = M::Store.path_for("localhost", 4000, dir: dir)

      first = M::Cartographer.new(runner: FakeWorldRunner.new("The Common Square", WORLD, TEXT),
                                  store: M::Store.new(path))
      walk_the_strip(first)
      assert File.exist?(path), "the map was written as it played"

      # A new day, a new process. Boukensha quit, the character stayed put.
      runner = FakeWorldRunner.new("The Common Square", WORLD, TEXT)
      second = M::Cartographer.new(runner: runner, store: M::Store.new(path))
      assert_equal "The Common Square", second.world.current&.title,
                   "position is what makes the next session start instantly"

      out = second.goto("temple square")
      assert_includes out, "Arrived at The Temple Square"
      assert_equal "The Temple Square", runner.here
      assert_equal %w[north north], runner.sent, "it routed straight there, with no look and no wandering"
    end
  end

  # ── the MCP surface ─────────────────────────────────────────────────────────

  def test_the_map_tools_are_advertised
    names = MudManager::Mcp::Spec.mcp_tools.map { |t| t["name"] }

    assert_includes names, "map_where"
    assert_includes names, "map_goto"
    assert_includes names, "map_explore"
    assert_includes names, "map_back"
  end

  # ── going home ──────────────────────────────────────────────────────────────
  #
  # Exploring only ever walks outward, and the map deliberately does not invent
  # the reverse of an edge, because MUDs have one-way exits. Left there, the map
  # is all arrows pointing away from home and map_goto can never bring you back.
  # The answer is not to assume the reverse but to TEST it.

  def test_exploring_leaves_no_recorded_way_back
    c = carto
    c.where
    3.times { c.explore_once }

    home = c.world.rooms.values.find { |r| r.title == "The Common Square" }
    assert_nil MudManager::Map::Pathfinder.route(c.world, from: c.world.position, to: home.id, presume: false),
               "nothing walked leads home yet, which is exactly the problem map_back solves"
  end

  def test_map_back_retraces_and_teaches_the_map_the_way_home
    c = carto
    c.where
    c.step("north")
    c.step("north")
    assert_equal "The Temple Square", @runner.here

    out = c.back
    assert_includes out, "The Common Square"
    assert_includes out, "south,south"
    assert_equal "The Common Square", @runner.here
    assert_empty c.trail

    # And now the way home is walked, not merely listed, so ordinary routing
    # finds it without needing to fall back on anything.
    temple = c.world.rooms.values.find { |r| r.title == "The Temple Square" }
    route  = MudManager::Map::Pathfinder.route(c.world, from: temple.id, to: c.world.position, presume: false)
    assert_equal %w[south south], route.directions
  end

  # Going back is navigation. If the map knows a shorter way than the wandering
  # route we took, Dijkstra takes it.
  def test_map_back_prefers_a_shorter_known_route_over_retracing
    c = carto
    c.where
    c.step("north")       # Market
    c.step("north")       # Temple
    c.step("south")       # Market again: the trail now has a pointless there-and-back
    c.step("north")       # Temple again
    @runner.sent.clear

    c.back
    assert_equal "The Common Square", @runner.here
    assert_equal %w[south south], @runner.sent.grep(/^(north|south|east|west|up|down)$/),
                 "two moves home, not four moves of retracing"
  end

  def test_map_back_can_undo_only_part_of_the_trail
    c = carto
    c.where
    c.step("north")
    c.step("north")

    assert_includes c.back(steps: 1), "Market Square"
    assert_equal "Market Square", @runner.here
    assert_equal 1, c.trail.size, "the rest of the trail survives for a second call"
  end

  # The hypothesis is tested, not assumed. When the reverse does NOT go back,
  # that is a finding: it gets recorded as an edge to wherever it really went,
  # and the retrace stops rather than flailing.
  def test_a_reverse_that_does_not_lead_home_is_recorded_as_what_it_is
    c = carto(start: "The Common Square",
              overrides: { ["Market Square", "south"] => F::DOORED_ROOM })
    c.where
    c.step("north")
    market = c.world.position

    out = c.back
    assert_includes out, "The Reading Room"
    refute_includes out, "Arrived at The Common Square"

    edge = c.world.edge(market, "south")
    refute_nil edge.to, "the refuted hypothesis still taught us where south actually goes"
    assert_equal "The Reading Room", c.world.room(edge.to).title
  end

  # Never assume: ask. Arriving anywhere new triggers one `exits` listing, so a
  # room can never end up with no idea where its own exits lead. This is what
  # stops the agent stranding itself in a room the search cannot leave.
  def test_arriving_anywhere_new_asks_the_game_where_its_exits_go
    c = carto
    c.where
    @runner.sent.clear
    c.step("north")

    assert_equal %w[north exits], @runner.sent
    here = c.world.current
    refute_nil here.listed_seq
    assert c.world.edges_from(here.id).any?(&:expected_title),
           "the new room knows where at least one of its exits leads"
  end

  def test_a_room_is_only_listed_once
    c = carto
    c.where
    c.step("north")
    c.back
    @runner.sent.clear
    c.step("north")

    assert_equal ["north"], @runner.sent, "already listed, so no second listing"
  end

  # A listed destination is a lead, not a traversal. The search may follow it,
  # at a premium, and the arrival check settles it.
  def test_a_listed_destination_is_routable_before_it_is_walked
    c = carto
    c.where
    home = c.world.position

    c.step("north")   # Market Square, whose listing names south -> The Common Square
    market = c.world.position
    assert_nil c.world.edge(market, "south").to, "south has never been walked"

    presumed = MudManager::Map::Pathfinder.route(c.world, from: market, to: home)
    confirmed = MudManager::Map::Pathfinder.route(c.world, from: market, to: home, presume: false)
    assert_equal %w[south], presumed.directions
    assert_nil confirmed, "and it is not pretending the edge was walked"
    assert presumed.steps.first.presumed
  end

  def test_map_back_with_nothing_walked_says_so
    assert_includes carto.back, "nothing to retrace"
  end

  def test_map_explore_can_take_several_steps_in_one_call
    c = carto
    c.where
    before = c.world.room_count
    out = c.explore(count: 3)

    assert_operator out.lines.size, :>, 1
    assert_operator c.world.room_count, :>, before
  end

  # §9 — each schema costs tokens on every single call against a median
  # 15,001-token call, and F23 deleted a whole server over exactly this.
  def test_the_map_keeps_its_tool_count_small
    navigation = MudManager::Mcp::ToolSpec.all.select { |t| t[:category] == "navigation" }
    assert_equal %w[map_where map_goto map_explore map_follow map_back],
                 navigation.map { |t| t[:name] }
  end

  def test_map_goto_requires_a_destination
    assert_equal ["destination"],
                 MudManager::Mcp::Spec.input_schema(MudManager::Mcp::ToolSpec.find("map_goto"))["required"]
  end

  def test_the_dispatcher_routes_map_tools_and_rejects_a_blank_destination
    fake = FakeMud.new
    begin
      dispatcher = MudManager::Mcp::Dispatcher.new(pool_for(fake), map_dir: Dir.mktmpdir)
      err = assert_raises(MudManager::Mcp::ProtocolError) do
        dispatcher.call("map_goto", { "destination" => "  " })
      end
      assert_equal "argument_error", err.code
    ensure
      fake.stop
    end
  end
end
