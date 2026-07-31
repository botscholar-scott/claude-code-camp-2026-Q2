require_relative "helper"
require_relative "map_fixtures"
require "tmpdir"

# §6.1 the map is a stored artifact, §6.5 merges must be reversible,
# §6.6 verification is self-derived.
class TestMapWorld < Minitest::Test
  M = MudManager::Map
  F = MapFixtures

  def setup
    @world = M::World.new
  end

  def move(direction, result)
    M::Projection.apply(@world, "move", { "direction" => direction }, result)
  end

  def test_dead_reckoning_records_coordinates
    move("north", F::MARKET_SQUARE)
    assert_equal [0, 0, 0], @world.current.coords
    move("north", F::TEMPLE_SQUARE)
    assert_equal [0, 1, 0], @world.current.coords
    move("south", F::MARKET_SQUARE)
    move("east", F::COMMON_SQUARE)
    assert_equal [1, 0, 0], @world.current.coords
  end

  # §6.6 degree invariant: a room announcing four exits can never accumulate a
  # fifth outbound edge. The audit is re-derivable from the stored map alone.
  def test_the_degree_invariant_catches_an_impossible_edge
    move("north", F::CELLAR)   # announces n and d only
    here = @world.position
    assert_empty @world.audit

    @world.record_edge(from: here, direction: "west", to: here, seq: 99)
    refute_empty @world.audit
    assert_equal "degree", @world.audit.first["kind"]
  end

  # §6.5 — because a wrong merge is discovered late, by contradiction, the
  # projection has to be able to SPLIT a node it previously merged. The
  # evidence sequence on each edge is what lets its edges be reassigned to the
  # right side of the split. Without it one bad merge is permanent and silently
  # poisons every path through that room.
  def test_a_merged_room_can_be_split_back_apart
    move("north", F::MARKET_SQUARE)
    market = @world.position
    move("north", F::TEMPLE_SQUARE)          # reached the first time from Market
    temple = @world.position
    move("south", F::MARKET_SQUARE)
    move("east",  F::COMMON_SQUARE)
    common = @world.position
    split_at = @world.seq + 1

    move("north", F::TEMPLE_SQUARE)          # reached again, this time from Common
    move("west",  F::DOORED_ROOM)            # and walked onward, all after the split point
    reading = @world.position
    rooms_before = @world.room_count

    twin = @world.split(temple, from_seq: split_at)

    assert_equal rooms_before + 1, @world.room_count
    assert_equal temple, @world.edge(market, "north").to,
                 "the early traversal still points at the original node"
    assert_equal twin.id, @world.edge(common, "north").to,
                 "an inbound edge established after the split point was reassigned"
    assert_equal reading, @world.edge(twin.id, "west").to,
                 "so was the outbound edge walked after it"
    assert_nil @world.edge(temple, "west").to,
               "the original keeps only what it can still account for"
    assert_nil twin.key, "the split-off copy is keyless so it cannot silently re-absorb arrivals"
  end

  def test_absorbing_a_placeholder_keeps_both_sets_of_edges
    move("north", F::MARKET_SQUARE)
    market = @world.position
    move("south", F::PITCH_BLACK)
    dark = @world.position
    @world.record_edge(from: dark, direction: "east", to: market, seq: @world.next_seq)

    move("north", F::MARKET_SQUARE)
    move("south", F::COMMON_SQUARE)
    common = @world.position

    refute @world.rooms.key?(dark)
    assert_equal market, @world.edge(common, "east").to, "the placeholder's outbound edge survived"
    assert_equal common, @world.edge(market, "south").to
  end

  # §6.1 — play for fifty hours, map the city, come back tomorrow, and it
  # already knows the way. `position` is what makes the next session start
  # instantly.
  def test_the_map_round_trips_through_the_store
    move("north", F::MARKET_SQUARE)
    move("north", F::TEMPLE_SQUARE)
    move("west",  F::DOORED_ROOM)

    Dir.mktmpdir do |dir|
      path  = M::Store.path_for("localhost", 4000, dir: dir)
      store = M::Store.new(path)
      store.save(@world)

      loaded = M::Store.new(path).load
      assert_equal @world.room_count, loaded.room_count
      assert_equal @world.edge_count, loaded.edge_count
      assert_equal @world.position,   loaded.position
      assert_equal "The Reading Room", loaded.current.title
      assert_equal :closed_door, loaded.edge(loaded.position, "west").status
      refute loaded.dirty?
    end
  end

  def test_a_corrupt_map_costs_the_exploration_not_the_session
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.json")
      File.write(path, "{not json")
      assert_equal 0, M::Store.new(path).load.room_count
    end
  end

  def test_a_missing_map_file_loads_an_empty_world
    Dir.mktmpdir do |dir|
      assert_equal 0, M::Store.new(File.join(dir, "nope.json")).load.room_count
    end
  end
end
