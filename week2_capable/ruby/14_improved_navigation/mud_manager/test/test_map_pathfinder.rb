require_relative "helper"

# §3 — the pathfinder takes state as a parameter. We never mutate the graph
# when the character picks up a key; edges carry predicates and those are
# evaluated against a state passed in.
class TestMapPathfinder < Minitest::Test
  M = MudManager::Map

  # A hand-built world, so the search is tested against a graph whose shape is
  # obvious rather than against whatever the parser happened to produce.
  #
  #     a --e-- b --e-- c
  #     |               |
  #     s               s
  #     |               |
  #     d --e-- e --e-- f
  #
  def setup
    @world = M::World.new
    @id = {}
    %w[a b c d e f].each_with_index do |name, i|
      room = @world.mint(key: name, title: name.upcase, description: "room #{name}",
                         exits: [], doors: [], coords: [i, 0, 0], seq: 1)
      @id[name] = room.id
    end
    link("a", "east", "b"); link("b", "east", "c")
    link("a", "south", "d"); link("c", "south", "f")
    link("d", "east", "e"); link("e", "east", "f")
    @world.position = @id["a"]
  end

  def link(from, direction, to, status: :open, requires: nil)
    @world.record_edge(from: @id[from], direction: direction, to: @id[to],
                       status: status, requires: requires, seq: @world.next_seq)
  end

  def route(to, state: {}, from: "a")
    M::Pathfinder.route(@world, from: @id[from], to: @id[to], state: state)
  end

  def test_finds_the_shortest_route_between_known_rooms
    assert_equal %w[east east], route("c").directions
  end

  def test_no_route_between_disconnected_rooms_is_nil
    orphan = @world.mint(key: "z", title: "Z", description: "elsewhere",
                         exits: [], doors: [], coords: [9, 9, 9], seq: 1)
    assert_nil M::Pathfinder.route(@world, from: @id["a"], to: orphan.id)
  end

  def test_a_route_to_where_you_already_stand_is_empty
    assert_empty route("a").directions
  end

  # With mobs and doors in play the edges genuinely differ, which is where
  # Dijkstra earns its keep over BFS: uniform-cost search cannot express "go
  # the long way around the ogre".
  def test_it_goes_the_long_way_around_a_blocked_edge
    link("a", "east", "b", status: :blocked_by_mob)

    assert_equal %w[south east east], route("f").directions,
                 "the two-step route through the mob is refused for the three-step way round"
  end

  # §8 step 2 — try north, get "the door is closed", mark the edge, and the
  # pathfinder routes around it with no planner involved. Nothing in the tool
  # surface opens doors, so by default a shut door is a wall; `open_doors` in
  # the state is what makes it merely expensive.
  def test_a_shut_door_is_routed_around_by_default
    link("a", "south", "d", status: :closed_door)

    assert_equal %w[east east south], route("f").directions
  end

  def test_a_shut_door_becomes_expensive_rather_than_impassable_with_state
    link("a", "south", "d", status: :closed_door)
    link("c", "south", "f", status: :blocked_by_mob)

    assert_nil route("f"), "both ways round are shut"
    assert_equal %w[south east east], route("f", state: { "open_doors" => true }).directions
  end

  def test_an_edge_that_needs_an_item_is_impassable_without_it
    link("a", "east", "b", status: :needs_item, requires: ["boat"])
    link("a", "south", "d", status: :blocked_by_mob)

    assert_nil route("c"), "no way to c without a boat"
  end

  # §3 — this is what buys counterfactual queries, and those are how subgoals
  # get derived instead of guessed: "could I reach the crypt if I held the
  # brass key?" If yes, "get the brass key" is now a subgoal, discovered from
  # the map.
  def test_the_same_query_succeeds_under_a_hypothetical_state
    link("a", "east", "b", status: :needs_item, requires: ["boat"])
    link("a", "south", "d", status: :blocked_by_mob)

    assert_nil route("c")
    assert_equal %w[east east], route("c", state: { "boat" => true }).directions
  end

  def test_a_mob_in_the_way_can_also_be_made_hypothetical
    link("a", "east", "b", status: :blocked_by_mob)

    assert_equal %w[south east east], route("f").directions, "the long way round the ogre"

    link("d", "east", "e", status: :closed_door)
    assert_nil route("c"), "now neither way is open"
    assert_equal %w[east east], route("c", state: { "pass_mobs" => true }).directions,
                 "fighting through is a route once the state says it is possible"
  end

  # A beatable mob is expensive, not free: even when the state permits passing
  # it, a plainly longer route can still win.
  def test_a_passable_mob_still_costs_more_than_walking_round
    link("a", "east", "b", status: :blocked_by_mob)

    assert_equal %w[south east east],
                 route("f", state: { "pass_mobs" => true }).directions
  end

  # §6.7 — an unexplored exit is the target of exploration, never a step on a
  # route to somewhere known.
  def test_frontier_edges_are_never_used_as_route_steps
    @world.record_edge(from: @id["a"], direction: "north", to: nil, seq: 99, status: :unknown)

    assert_equal %w[east east], route("c").directions
  end

  def test_nearest_frontier_is_the_cheapest_one_to_reach_not_an_arbitrary_pick
    @world.record_edge(from: @id["f"], direction: "north", to: nil, seq: 90, status: :unknown)
    @world.record_edge(from: @id["b"], direction: "north", to: nil, seq: 91, status: :unknown)

    route, edge = M::Pathfinder.nearest_frontier(@world, from: @id["a"])
    assert_equal %w[east], route.directions
    assert_equal @id["b"], edge.from
    assert_equal "north", edge.direction
  end

  def test_a_frontier_in_the_current_room_needs_no_walk
    @world.record_edge(from: @id["a"], direction: "north", to: nil, seq: 92, status: :unknown)

    route, edge = M::Pathfinder.nearest_frontier(@world, from: @id["a"])
    assert_empty route.directions
    assert_equal @id["a"], edge.from
  end

  def test_no_frontier_left_is_reported_as_nil
    route, edge = M::Pathfinder.nearest_frontier(@world, from: @id["a"])
    assert_nil route
    assert_nil edge
  end

  # §6.7 — for destinations you return to constantly, one single-source search
  # from the destination over reversed edges gives a distance field, and
  # navigation becomes greedy descent with no search per move.
  def test_a_distance_field_supports_greedy_descent
    field = M::Pathfinder.distance_field(@world, to: @id["c"])

    assert_equal 0, field[@id["c"]]
    assert_equal 1, field[@id["b"]]
    assert_equal 2, field[@id["a"]]

    step = M::Pathfinder.descend(@world, field, from: @id["a"])
    assert_equal "east", step.direction
    assert_nil M::Pathfinder.descend(@world, field, from: @id["c"]), "already there"
  end

  def test_the_distance_field_respects_the_same_predicates
    link("b", "east", "c", status: :needs_item, requires: ["boat"])

    refute M::Pathfinder.distance_field(@world, to: @id["c"]).key?(@id["a"])
    assert M::Pathfinder.distance_field(@world, to: @id["c"], state: { "boat" => true }).key?(@id["a"])
  end
end
