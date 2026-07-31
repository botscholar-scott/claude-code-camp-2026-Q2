require_relative "helper"

# §8.1 — build it as a replay first.
#
# The thing that updates the map is a pure function
# (map, tool_name, args, result) -> map. Live it is fed one observation at a
# time; here it is fed two recorded sessions, which is the same function in a
# loop. That is what makes the corpus useful without making it authoritative:
# the map boukensha actually plays with is written as it walks (§6.1), and
# nothing here reads a world file (§8.2).
#
# The corpus is 99 real moves complete with ANSI codes, an interleaved Mayor
# broadcast, two pitch-black rooms, five parenthesised-door exit lines, one
# real closed-door failure and two boat refusals — with no MUD running and no
# tokens spent. §6.6's invariants holding across it is the cheapest available
# proof that the merge rule works.
class TestMapReplay < Minitest::Test
  M = MudManager::Map

  # The two session files that carry any navigation at all. The other ten hold
  # 0 to 3 tool calls each and are not useful as a corpus (§7.2).
  CORPUS = %w[
    20260728T020721Z-11017d94.jsonl
    20260730T030227Z-82215bf4.jsonl
  ].freeze

  # Walk up to the repo root rather than counting "..", which is what silently
  # turned boukensha's 15 MCP tests into skips when its helper was copied
  # forward into a tree one level deeper.
  def sessions_dir
    dir = __dir__
    dir = File.dirname(dir) until File.directory?(File.join(dir, ".boukensha", "sessions")) || dir == "/"
    File.join(dir, ".boukensha", "sessions")
  end

  def corpus_files
    CORPUS.map { |f| File.join(sessions_dir, f) }.select { |p| File.exist?(p) }
  end

  def replay(files)
    world = M::World.new
    stats = Hash.new(0)

    files.each do |path|
      calls   = []
      results = []
      File.foreach(path) do |line|
        rec = JSON.parse(line) rescue next
        calls   << rec if rec["phase"] == "tool_call"
        results << rec if rec["phase"] == "tool_result"
      end

      # §7.3: these two files predate the tool_use_id fix, but dispatch was a
      # serial `each` in the code that wrote them, so positional pairing is
      # sound for them specifically. §10.5: an unpaired call is not an
      # observation.
      calls.zip(results).each do |call, result|
        next if result.nil? || call["name"] != result["name"]
        res = M::Projection.apply(world, call["name"], call["args"], result["result"],
                                  ok: result["ok"] != false)
        stats[res.outcome] += 1
      end
    end

    [world, stats]
  end

  def test_the_invariants_hold_across_every_recorded_move
    files = corpus_files
    skip "corpus not present at #{sessions_dir}" if files.size < CORPUS.size

    world, stats = replay(files)

    # 94 arrivals with a room, 2 arrivals in the dark, 3 refusals — which is
    # exactly the 99 recorded moves. Nothing is unexplained (§5.1).
    assert_equal 94, stats[:arrived]
    assert_equal 2,  stats[:arrived_dark]
    assert_equal 3,  stats[:refused]
    assert_equal 0,  stats[:lost], "every reply in the corpus is classifiable"

    # §6.6: 0 edge-invariant and 0 exit-set violations in 99 moves, and the
    # degree invariant holds over the finished map.
    assert_empty world.violations
    assert_empty world.audit
  end

  # §6.2 — 34 distinct titles yield 37 distinct (title, description) pairs,
  # which is exactly the room count obtained independently by unioning the two
  # sessions. The 38th node is the one pitch-black room that never got lit.
  def test_conditional_minting_reproduces_the_measured_room_count
    files = corpus_files
    skip "corpus not present at #{sessions_dir}" if files.size < CORPUS.size

    world, = replay(files)
    keyed = world.rooms.values.reject(&:dark?)

    assert_equal 37, keyed.size
    assert_equal 37, keyed.map(&:key).uniq.size
    assert_equal 38, world.room_count
  end

  # §6.3 — capturing this is the point. Unconditional minting gives every
  # arrival its own node, so nothing is ever reachable two ways and roughly
  # half the map is phantom.
  def test_the_map_records_rooms_reachable_by_more_than_one_route
    files = corpus_files
    skip "corpus not present at #{sessions_dir}" if files.size < CORPUS.size

    world, = replay(files)
    multi = world.rooms.keys.count { |id| world.edges_to(id).map(&:from).uniq.size > 1 }

    assert_operator multi, :>=, 20
  end

  # §6.7 — every visited room contributes unvisited edges, which is what turns
  # "find location X" from wandering into a search with a real frontier.
  def test_the_replayed_map_has_a_frontier_to_explore
    files = corpus_files
    skip "corpus not present at #{sessions_dir}" if files.size < CORPUS.size

    world, = replay(files)

    assert_operator world.frontier_edges.size, :>, 20
    assert_operator world.edges.values.count { |e| e.to }, :>, 60
  end
end
