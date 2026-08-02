require_relative "helper"
require_relative "map_fixtures"

# §5 — what tbaMUD actually hands you. The parser anchors on ANSI colour
# because the colour codes are structure, not noise.
class TestMapParser < Minitest::Test
  P = MudManager::Map::Parser

  def test_parses_title_description_and_exits
    obs = P.parse(MapFixtures::TEMPLE_SQUARE)

    assert_equal :room, obs.kind
    assert_equal "The Temple Square", obs.title
    assert_includes obs.description, "Huge marble steps lead up to the"
    assert_equal %w[north east south west], obs.exits
    assert_empty obs.doors
  end

  def test_description_stops_at_the_exits_line
    obs = P.parse(MapFixtures::TEMPLE_SQUARE)
    refute_includes obs.description, "fountain", "objects live below the exits line, not in the description"
    refute_includes obs.description, "The Temple Square", "the title is not part of the description"
  end

  # Mobs are yellow too. Only their position below the exits line tells them
  # apart from the title, which is why the parser must not strip ANSI first.
  def test_mobs_below_the_exits_line_are_not_the_title
    obs = P.parse(MapFixtures::COMMON_SQUARE)

    assert_equal "The Common Square", obs.title
    refute_includes obs.description, "beastly fido"
  end

  def test_parenthesised_directions_are_doors_and_still_exits
    obs = P.parse(MapFixtures::DOORED_ROOM)

    assert_equal %w[north south west], obs.exits
    assert_equal %w[west], obs.doors
  end

  def test_every_exit_can_be_a_door
    obs = P.parse(MapFixtures::ALL_DOORS)

    assert_equal %w[north east south west], obs.exits
    assert_equal %w[north east], obs.doors
  end

  def test_up_and_down_are_in_the_direction_set
    obs = P.parse(MapFixtures::CELLAR)
    assert_equal %w[north down], obs.exits
  end

  # The status prompt rides along on every response, so HP/mana/movement come
  # for free without a separate `check` (§5, "free state").
  def test_vitals_come_from_the_prompt_line
    assert_equal({ "hp" => 25, "mana" => 100, "move" => 83 },
                 P.parse(MapFixtures::TEMPLE_SQUARE).vitals)
  end

  def test_pitch_black_is_a_successful_move_not_a_failure
    obs = P.parse(MapFixtures::PITCH_BLACK)

    assert_equal :dark, obs.kind
    assert obs.moved?, "a dark room means you arrived somewhere unidentifiable, not that you stayed put"
  end

  def test_known_refusals_are_classified_and_verified
    door = P.parse(MapFixtures::CLOSED_DOOR)
    assert_equal :refused, door.kind
    assert_equal :closed_door, door.reason
    assert door.verified
    refute door.moved?

    boat = P.parse(MapFixtures::NEEDS_BOAT)
    assert_equal :refused, boat.kind
    assert_equal :needs_boat, boat.reason
  end

  # §5.1: the corpus does not contain the whole failure taxonomy, so an
  # unrecognised reply must be "position unknown, re-localize" — never a
  # successful move.
  def test_unrecognised_replies_are_unparsed
    obs = P.parse(MapFixtures::UNKNOWN_REPLY)

    assert_equal :unparsed, obs.kind
    refute obs.moved?
  end

  # A refusal the parser has no pattern for is reported as exactly that:
  # unclassified. It is not guessed at. Measured on the corpus, guessing loses:
  # every reply the guessed patterns were written for never occurred, while the
  # four that did occur were not among them. Cartographer#settle establishes
  # what actually happened, by looking.
  def test_a_refusal_with_unknown_wording_is_not_guessed_at
    [
      "Alas, you cannot go that way.\r\n\r\n25H 100M 80V > ",
      "You are too exhausted.\r\n\r\n25H 100M 0V > ",
      "Maybe you should get on your feet first?\r\n\r\n25H 100M 80V > "
    ].each do |reply|
      obs = P.parse(reply)
      assert_equal :unparsed, obs.kind, reply.lines.first
      refute obs.moved?, "and above all it is never reported as a move that worked"
    end
  end

  # `look` gives the direction set. `exits` gives the direction set AND the
  # name of the room behind each one, which is the information that lets an
  # unwalked exit become a routable destination.
  def test_the_exits_listing_names_every_destination
    obs = P.parse(MapFixtures::EXIT_LISTING)

    assert_equal :exit_list, obs.kind
    assert_equal "By The Temple Altar", obs.destinations["north"]
    assert_equal "The Reading Room",    obs.destinations["west"]
    assert_equal 5, obs.destinations.size
    refute obs.moved?, "asking where the exits go does not move you"
  end

  def test_two_exits_may_name_the_same_room
    obs = P.parse(MapFixtures::EXIT_LISTING)

    assert_equal "The Temple Square", obs.destinations["south"]
    assert_equal "The Temple Square", obs.destinations["down"]
  end

  def test_a_broadcast_arriving_during_the_listing_is_skipped
    obs = P.parse(MapFixtures::EXIT_LISTING_WITH_BROADCAST)

    assert_equal :exit_list, obs.kind
    assert_equal 5, obs.destinations.size
    assert_equal "By The Temple Altar", obs.destinations["north"]
    refute obs.destinations.values.any? { |v| v.include?("booming") }
  end

  # `exits` and `exit` are the same command. The structured tool sends the
  # plural via INFO_SELF; the raw escape hatch takes either.
  def test_both_spellings_reach_the_map
    assert_equal "exits", MudManager::Primitives.info_self("exits").raw

    %w[exit exits].each do |spelling|
      world = MudManager::Map::World.new
      MudManager::Map::Projection.apply(world, "move", { "direction" => "north" },
                                        MapFixtures::TEMPLE_SQUARE)
      here = world.position
      MudManager::Map::Projection.apply(world, "send_raw", { "command" => spelling },
                                        MapFixtures::EXIT_LISTING)

      assert_equal "By The Temple Altar", world.edge(here, "north").expected_title,
                   "#{spelling.inspect} should label the edges"
    end
  end

  def test_a_short_exits_listing_parses
    obs = P.parse(MapFixtures::EXIT_LISTING_SHORT)

    assert_equal :exit_list, obs.kind
    assert_equal({ "north" => "The Dark Alley At The Levee", "south" => "On The River" },
                 obs.destinations)
  end

  # The parser reports every label the listing gave, verbatim, including the
  # ones that are plainly not room names. Deciding which sentences a server
  # substitutes for a title is not the parser's job and cannot be done from a
  # fixed list without breaking on the next MUD.
  def test_every_label_the_listing_gave_is_reported_verbatim
    obs = P.parse(MapFixtures::EXIT_LISTING_UNNAMED)

    assert_equal :exit_list, obs.kind
    assert_equal 4, obs.destinations.size
    assert_equal "The Shadow Grove",      obs.destinations["east"]
    assert_equal "Too dark to tell.",     obs.destinations["north"]
    assert_equal "The door is closed.",   obs.destinations["west"]
  end

  # A room block and an exits listing are different observations and must not
  # be confused: one identifies where you are, the other says what is adjacent.
  def test_a_room_block_is_not_read_as_an_exits_listing
    assert_equal :room, P.parse(MapFixtures::TEMPLE_SQUARE).kind
  end

  def test_an_uncoloured_broadcast_is_not_a_room
    assert_equal :unparsed, P.parse(MapFixtures::MAYOR).kind
  end

  # §6.2 — identity is the pair, hashed. Not the title alone: "Main Street"
  # covers three physically distinct rooms.
  def test_identity_key_separates_rooms_that_share_a_title
    a = P.parse(MapFixtures::MAIN_STREET_A)
    b = P.parse(MapFixtures::MAIN_STREET_B)

    assert_equal a.title, b.title
    refute_equal a.key, b.key
  end

  def test_identity_key_is_stable_across_visits
    assert_equal P.parse(MapFixtures::MARKET_SQUARE).key,
                 P.parse(MapFixtures::MARKET_SQUARE).key
  end

  # Mobs and objects wander in and out; they must not change the room's key,
  # which is exactly why they sit below the exits line.
  def test_mobs_do_not_change_the_identity_key
    without_mobs = MapFixtures::COMMON_SQUARE.sub(/A beastly fido.*/m, "\r\n25H 100M 81V > ")

    assert_equal P.parse(MapFixtures::COMMON_SQUARE).key, P.parse(without_mobs).key
  end
end
