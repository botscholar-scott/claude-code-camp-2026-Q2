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
  # If the two disagree, that is a contradiction, not a silent overwrite.
  def test_walking_an_exit_that_was_listed_wrongly_raises_a_contradiction
    c = carto(start: "The Common Square",
              overrides: { ["The Common Square", "north"] => F::TEMPLE_SQUARE })
    c.where
    c.step("north")

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
    out = c.explore

    assert_includes out, "Explored"
    refute c.world.edge(chosen.from, chosen.direction).frontier?,
           "the exit it picked is no longer untried"
    assert_operator c.world.room_count, :>=, 2
  end

  def test_map_explore_says_so_when_the_map_is_exhausted_of_frontier
    c = carto(world: M::World.new)
    c.where
    30.times { break if c.world.frontier_edges.empty?; c.explore }

    assert_includes c.explore, "No unexplored exits"
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

  def test_the_three_map_tools_are_advertised
    names = MudManager::Mcp::Spec.mcp_tools.map { |t| t["name"] }

    assert_includes names, "map_where"
    assert_includes names, "map_goto"
    assert_includes names, "map_explore"
  end

  # §9 — each schema costs tokens on every single call against a median
  # 15,001-token call, and F23 deleted a whole server over exactly this.
  def test_the_map_adds_only_three_tools
    navigation = MudManager::Mcp::ToolSpec.all.select { |t| t[:category] == "navigation" }
    assert_equal 3, navigation.size
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
