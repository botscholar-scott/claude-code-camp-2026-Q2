require_relative "helper"
require_relative "map_fixtures"

# §6 — how the map gets recorded. The atom is the traversal event
# (from, direction, to); everything else is derived from a sequence of those.
class TestMapProjection < Minitest::Test
  M = MudManager::Map
  F = MapFixtures

  def setup
    @world = M::World.new
  end

  def move(direction, result, ok: true)
    M::Projection.apply(@world, "tbamud__move", { "direction" => direction }, result, ok: ok)
  end

  def look(result, args = {})
    M::Projection.apply(@world, "tbamud__look", args, result)
  end

  def test_first_arrival_mints_a_room_and_sets_position
    res = move("north", F::TEMPLE_SQUARE)

    assert_equal :arrived, res.outcome
    assert_equal 1, @world.room_count
    assert_equal "The Temple Square", @world.current.title
  end

  def test_traversal_records_an_edge_from_the_previous_room
    move("north", F::MARKET_SQUARE)
    from = @world.position
    move("north", F::TEMPLE_SQUARE)

    edge = @world.edge(from, "north")
    assert_equal @world.position, edge.to
    assert_equal :open, edge.status
  end

  # §6.7 — never auto-create the reverse edge. A north from A to B does not
  # imply a south from B to A; the difference between "confirmed both ways" and
  # "seen one way" is real information.
  def test_the_reverse_edge_is_not_invented
    move("north", F::MARKET_SQUARE)
    market = @world.position
    move("north", F::TEMPLE_SQUARE)
    temple = @world.position

    assert_nil @world.edge(temple, "south").to,
               "the way back is announced as an exit but has not been walked"
    assert_equal market, @world.edge(market, "north").from
  end

  # §6.7 — `[ Exits: n e s w ]` tells you a room has four exits before you have
  # walked any of them, which is what gives exploration a real frontier.
  def test_announced_exits_become_frontier_edges
    move("north", F::TEMPLE_SQUARE)

    assert_equal 4, @world.edges_from(@world.position).size
    assert_equal 4, @world.frontier_edges.size
  end

  def test_doors_are_marked_before_they_are_ever_walked
    move("north", F::DOORED_ROOM)

    assert_equal :closed_door, @world.edge(@world.position, "west").status
    assert_equal :unknown,     @world.edge(@world.position, "north").status
  end

  # §6.3 — minting is conditional. Go n,n and then n,e,w,n: the e-then-w is a
  # round trip, so both routes end in the same room. Minting on every arrival
  # would make that room two places and a phantom wing of the building.
  def test_a_round_trip_does_not_mint_a_phantom_room
    move("north", F::MARKET_SQUARE)
    market = @world.position
    move("north", F::TEMPLE_SQUARE)
    move("south", F::MARKET_SQUARE)

    assert_equal market, @world.position
    assert_equal 2, @world.room_count
  end

  def test_rooms_sharing_a_title_are_kept_apart_by_description
    move("east", F::MAIN_STREET_A)
    move("east", F::MAIN_STREET_B)

    assert_equal 2, @world.room_count
    assert_equal ["Main Street", "Main Street"], @world.rooms.values.map(&:title)
  end

  def test_arrivals_reuse_a_node_reached_by_a_second_route
    move("north", F::MARKET_SQUARE)
    move("north", F::TEMPLE_SQUARE)
    temple = @world.position
    move("south", F::MARKET_SQUARE)
    move("east",  F::COMMON_SQUARE)
    move("north", F::TEMPLE_SQUARE)

    assert_equal temple, @world.position, "the same room reached two ways is one node"
    assert_equal 2, @world.edges_to(temple).map(&:from).uniq.size
  end

  # §5 — pitch black means the move SUCCEEDED; the room just cannot identify
  # itself. Treating it as a failure would corrupt the position.
  def test_a_dark_room_is_an_arrival
    move("north", F::MARKET_SQUARE)
    market = @world.position
    res = move("south", F::PITCH_BLACK)

    assert_equal :arrived_dark, res.outcome
    refute_equal market, @world.position
    assert @world.current.dark?
    assert_equal @world.position, @world.edge(market, "south").to
  end

  # Identity in the dark depends on movement history or a light source (§5).
  # Coming back with one must not leave two nodes for one room.
  def test_a_dark_room_is_absorbed_once_it_can_be_identified
    move("north", F::MARKET_SQUARE)
    market = @world.position
    move("south", F::PITCH_BLACK)
    move("north", F::MARKET_SQUARE)
    move("south", F::COMMON_SQUARE)

    assert_equal 2, @world.room_count, "the dark placeholder folds into the room it turned out to be"
    assert_equal "The Common Square", @world.current.title
    assert_equal @world.position, @world.edge(market, "south").to
    assert_empty @world.violations
  end

  def test_a_second_dark_visit_is_recognised_by_movement_history
    move("north", F::MARKET_SQUARE)
    market = @world.position
    move("south", F::PITCH_BLACK)
    dark = @world.position
    move("north", F::MARKET_SQUARE)
    move("south", F::PITCH_BLACK)

    assert_equal dark, @world.position
    assert_equal 2, @world.room_count
    assert_equal market, @world.edge(market, "south").from
  end

  # §8 step 2 — try north, get "the door is closed", mark the edge. The
  # pathfinder then routes around it with no planner involved.
  def test_a_refusal_annotates_the_edge_and_leaves_position_alone
    move("north", F::DOORED_ROOM)
    here = @world.position
    res  = move("west", F::CLOSED_DOOR)

    assert_equal :refused, res.outcome
    assert_equal here, @world.position
    assert_equal :closed_door, @world.edge(here, "west").status
    assert_nil @world.edge(here, "west").to
  end

  def test_a_boat_refusal_records_what_the_edge_requires
    move("north", F::TEMPLE_SQUARE)
    here = @world.position
    move("east", F::NEEDS_BOAT)

    edge = @world.edge(here, "east")
    assert_equal :needs_item, edge.status
    assert_equal ["boat"], edge.requires
  end

  # §5.1 — an unrecognised reply has to be treated as "position unknown,
  # re-localize", never as a successful move.
  def test_an_unparsed_reply_clears_the_position
    move("north", F::TEMPLE_SQUARE)
    res = move("east", F::UNKNOWN_REPLY)

    assert_equal :lost, res.outcome
    assert_nil @world.position
    assert_equal 1, @world.room_count
  end

  # §6.2 — re-localization is one `look`. That is what makes a map built
  # yesterday usable today.
  def test_a_look_relocalizes_without_moving
    move("north", F::MARKET_SQUARE)
    market = @world.position
    move("east", F::UNKNOWN_REPLY)
    assert_nil @world.position

    res = look(F::MARKET_SQUARE)
    assert_equal :relocalized, res.outcome
    assert_equal market, @world.position
    assert_equal 1, @world.room_count
  end

  def test_a_look_at_a_target_is_not_an_observation
    move("north", F::MARKET_SQUARE)
    market = @world.position

    assert_equal :ignored, look(F::TEMPLE_SQUARE, "target" => "fountain").outcome
    assert_equal market, @world.position
  end

  # §7.1 — `ok:false` is an MCP-level failure, not a blocked move. It means
  # "this call is not an observation".
  def test_a_failed_call_is_not_an_observation
    move("north", F::MARKET_SQUARE)
    market = @world.position
    res = move("north", "error [timeout]: no prompt", ok: false)

    assert_equal :ignored, res.outcome
    assert_equal market, @world.position
    assert_equal 1, @world.room_count
  end

  # An agent can move with the escape hatch, and an unobserved move desyncs the
  # position — which then routes confidently from the wrong room.
  def test_a_bare_direction_sent_raw_still_updates_the_map
    move("north", F::MARKET_SQUARE)
    market = @world.position
    res = M::Projection.apply(@world, "tbamud__send_raw", { "command" => "n" }, F::TEMPLE_SQUARE)

    assert_equal :arrived, res.outcome
    assert_equal "The Temple Square", @world.current.title
    assert_equal @world.position, @world.edge(market, "north").to
  end

  # `look north` peeks into the room NEXT DOOR and returns a full room block.
  # Accepting any room block off the raw channel would teleport the map.
  def test_a_directional_peek_sent_raw_is_ignored
    move("north", F::MARKET_SQUARE)
    market = @world.position

    res = M::Projection.apply(@world, "tbamud__send_raw", { "command" => "look north" }, F::TEMPLE_SQUARE)
    assert_equal :ignored, res.outcome
    assert_equal market, @world.position
    assert_equal 1, @world.room_count
  end

  def check_exits(result)
    M::Projection.apply(@world, "tbamud__check", { "kind" => "exits" }, result)
  end

  # The listing is an observation about the EDGES, not about rooms. Learning
  # that north leads to "By The Temple Altar" does not mean we have seen that
  # room, and a title is not a key anyway (§6.2).
  def test_an_exits_listing_labels_edges_and_mints_nothing
    move("north", F::TEMPLE_SQUARE)
    here = @world.position

    res = check_exits(F::EXIT_LISTING)
    assert_equal :labelled, res.outcome
    assert_equal 1, @world.room_count, "naming destinations creates no rooms"
    assert_equal "By The Temple Altar", @world.edge(here, "north").expected_title
    assert_nil @world.edge(here, "north").to, "it is still an exit nobody has walked"
    assert_equal here, @world.position
  end

  def test_a_labelled_edge_becomes_a_routable_destination
    move("north", F::TEMPLE_SQUARE)
    check_exits(F::EXIT_LISTING)

    named = @world.named_frontier_edges.map(&:expected_title)
    assert_includes named, "The Reading Room"
  end

  # Walking is what settles a label. Agreement is confirmation.
  def test_walking_a_labelled_edge_confirms_it_without_complaint
    move("north", F::MARKET_SQUARE)
    here = @world.position
    check_exits(MapFixtures.crlf(["Obvious exits:", "north - The Temple Square", "",
                                  "25H 100M 84V > "]))
    move("north", F::TEMPLE_SQUARE)

    assert_empty @world.violations
    assert_equal "The Temple Square", @world.room(@world.edge(here, "north").to).title
  end

  # Disagreement is a contradiction, surfaced rather than silently overwritten.
  def test_walking_a_labelled_edge_that_lied_raises_a_contradiction
    move("north", F::MARKET_SQUARE)
    check_exits(MapFixtures.crlf(["Obvious exits:", "north - The Bakery", "",
                                  "25H 100M 84V > "]))
    move("north", F::TEMPLE_SQUARE)

    assert_equal 1, @world.violations.size
    assert_equal "destination_conflict", @world.violations.first["kind"]
    assert_equal "The Temple Square", @world.current.title, "the observation still wins"
  end

  def test_an_exits_listing_with_no_known_position_is_ignored
    assert_equal :ignored, check_exits(F::EXIT_LISTING).outcome
    assert_equal 0, @world.room_count
  end

  def test_other_check_kinds_are_not_exit_listings
    move("north", F::TEMPLE_SQUARE)
    res = M::Projection.apply(@world, "tbamud__check", { "kind" => "gold" }, "You're broke!")

    assert_equal :ignored, res.outcome
  end

  # §6.6 as sharpened: a mismatch is a suspected wrong merge (§6.4), not an
  # invitation to invent a room with the union of both exit sets. A union is a
  # room that was never observed.
  def test_a_changed_exit_set_flags_a_suspected_wrong_merge
    move("north", F::CELLAR)             # announces n, d
    here = @world.position
    # Same title and description, different exits: the §6.4 collision.
    variant = F::CELLAR.sub("[ Exits: n d ]", "[ Exits: n s ]")
    move("north", F::MARKET_SQUARE)
    M::Projection.apply(@world, "move", { "direction" => "south" }, variant)

    assert_equal here, @world.position, "it is still recorded as the same room"
    assert @world.room(here).suspect?
    assert_equal "exit_set", @world.violations.first["kind"]
    assert_equal %w[north south], @world.room(here).exits.sort,
                 "the most recent observation is kept, not a union with the old one"
    refute_includes @world.room(here).exits, "down"
  end

  def test_unrelated_tools_are_ignored
    move("north", F::MARKET_SQUARE)
    before = @world.seq

    M::Projection.apply(@world, "tbamud__consider", { "target" => "fido" }, "You could take him.")
    assert_equal before, @world.seq
  end

  # §6.6 — the same room and the same direction must always lead to the same
  # node. A violation is a wrong merge surfacing, and it must be visible.
  def test_a_contradicting_edge_is_recorded_as_a_violation
    move("north", F::MARKET_SQUARE)
    market = @world.position
    move("north", F::TEMPLE_SQUARE)
    look(F::MARKET_SQUARE)
    move("north", F::COMMON_SQUARE)

    assert_equal 1, @world.violations.size
    assert_equal "edge_conflict", @world.violations.first["kind"]
    assert_equal market, @world.edge(market, "north").from
  end
end
