require "securerandom"

module MudManager
  module Map
    # World is the map itself: rooms, edges and the last known position (§6.1).
    # It is a stored artifact, written as you play and loaded at boot — never
    # re-derived from session logs, which are a debug trace.
    #
    # The atom is the traversal event, (from, direction, to). Everything else
    # here is derived from a sequence of those.
    #
    # World knows nothing about MUD text, pathfinding or files. The parser
    # feeds it Observations, Projection folds them in, Pathfinder reads it,
    # Store persists it.
    class World
      DIRECTIONS = %w[north east south west up down].freeze

      # Dead-reckoned offsets. Coordinates are corroboration, not the key
      # (§6.2): they make the map drawable and they are what catches a wrong
      # merge in a maze, because a bad merge warps them into a contradiction.
      DELTA = {
        "north" => [0, 1, 0], "south" => [0, -1, 0],
        "east"  => [1, 0, 0], "west"  => [-1, 0, 0],
        "up"    => [0, 0, 1], "down"  => [0, 0, -1]
      }.freeze

      REVERSE = {
        "north" => "south", "south" => "north",
        "east"  => "west",  "west"  => "east",
        "up"    => "down",  "down"  => "up"
      }.freeze

      # status values an edge can carry (§6.7). Each is established by an
      # observation whose sequence number is recorded in `evidence`.
      #   :unknown        announced in an exits line, never walked
      #   :open           walked successfully at least once
      #   :closed_door    pre-announced by parentheses, or refused with the
      #                   closed-door message
      #   :needs_item     refused for want of a boat (or similar)
      #   :blocked_by_mob something living is in the way
      #   :no_exit        the MUD says there is nothing there
      STATUSES = %i[unknown open closed_door needs_item blocked_by_mob no_exit blocked].freeze

      # `listed_seq` is when an `exits` listing was last folded in for this
      # room. Nil means nobody has ever asked. It is what stops the listing
      # being re-run on every visit: a second listing of an unchanged room
      # tells us exactly what the first one did.
      Room = Struct.new(:id, :key, :title, :description, :exits, :doors,
                        :coords, :flags, :first_seq, :last_seq, :listed_seq,
                        keyword_init: true) do
        def dark?    = flags.include?("dark")
        # Two observations of this room's exit set disagreed, which is what a
        # wrong merge of two same-key rooms looks like (§6.4).
        def suspect? = flags.include?("suspect_merge")
      end

      # `expected_title` is what the `exits` command said is on the other side.
      # It is an observation about the EDGE, not an identity for a room: the
      # title alone is not a key (§6.2 — three rooms are called "Main Street",
      # and in one observed listing two different exits both named "The Temple
      # Square"). It labels the edge until a traversal settles what is actually
      # there.
      Edge = Struct.new(:from, :direction, :to, :status, :requires,
                        :expected_title, :evidence, :last_seq, keyword_init: true) do
        # Never walked. May still have been named by an exits listing, and may
        # already have been attempted and refused.
        def frontier? = to.nil?

        # Never even attempted. `evidence` holds traversal sequences only, so an
        # exit announced by the exits line has none, while one that was walked,
        # or walked and refused, does. This is the exploration frontier: trying
        # it can still teach us something.
        def untried? = to.nil? && evidence.empty?
      end

      attr_reader :rooms, :edges, :violations
      attr_accessor :position, :seq

      def initialize
        @rooms      = {}   # id    => Room
        @by_key     = {}   # key   => id
        @edges      = {}   # [from, direction] => Edge
        @position   = nil
        @seq        = 0
        @violations = []
        @dirty      = false
      end

      def dirty? = @dirty
      def clean!  = (@dirty = false)

      def next_seq = (@seq += 1)

      def room(id)          = @rooms[id]
      def room_by_key(key)  = @rooms[@by_key[key]]
      def current           = @position && @rooms[@position]
      def room_count        = @rooms.size
      def edge_count        = @edges.size

      # ── recording ───────────────────────────────────────────────────────────

      # §6.3, minting is conditional. Hash (title, description); if a room with
      # that key exists you are standing in it, so reuse it. Only mint when the
      # key is new. A scheme that mints on every arrival makes two routes to
      # one room into a phantom wing of the building — measured, roughly half
      # of every such map is phantom.
      def observe_room(obs, seq:, coords: nil)
        key      = obs.key
        existing = @by_key[key]

        if existing
          merge_into(@rooms[existing], obs, seq)
          @rooms[existing]
        else
          mint(key: key, title: obs.title, description: obs.description,
               exits: obs.exits, doors: obs.doors, coords: coords, seq: seq)
        end
      end

      # A pitch-black room has neither title nor description, so identity there
      # falls back to dead reckoning (§6.3). Two dark arrivals at the same
      # coordinate are the same room; anything else mints.
      def observe_dark(seq:, coords:)
        found = @rooms.values.find { |r| r.dark? && r.coords == coords }
        return touch(found, seq) if found

        mint(key: nil, title: "(dark)", description: "", exits: [], doors: [],
             coords: coords, seq: seq, flags: ["dark"])
      end

      # A room previously known only as "somewhere dark at these coordinates"
      # turns out to be a room we can now identify — we came back with a light,
      # or arrived from a direction that lit it. §5 says identity in the dark
      # depends on movement history or a light source; this is the light
      # source. Fold the placeholder into the real room and keep every edge,
      # evidence intact so §6.5's split can still take it apart.
      def absorb(placeholder_id, room_id)
        return if placeholder_id == room_id
        placeholder = @rooms[placeholder_id] or return
        keeper      = @rooms[room_id]        or return

        @edges.values.to_a.each do |e|
          e.to = keeper.id if e.to == placeholder_id
          next unless e.from == placeholder_id
          @edges.delete([e.from, e.direction])
          e.from = keeper.id
          # The keeper may already have walked this direction; the older edge
          # wins its `to`, and the evidence of both is preserved.
          if (existing = @edges[[keeper.id, e.direction]])
            existing.evidence |= e.evidence
            existing.to ||= e.to
          else
            @edges[[keeper.id, e.direction]] = e
          end
        end

        @rooms.delete(placeholder_id)
        @by_key.delete(placeholder.key) if placeholder.key
        @position = keeper.id if @position == placeholder_id
        @dirty    = true
        keeper
      end

      def touch_room(id, seq)
        room = @rooms[id] or return nil
        touch(room, seq)
      end

      def mint(key:, title:, description:, exits:, doors:, coords:, seq:, flags: [])
        room = Room.new(
          id: SecureRandom.uuid, key: key, title: title, description: description,
          exits: Array(exits), doors: Array(doors), coords: coords,
          flags: Array(flags), first_seq: seq, last_seq: seq
        )
        @rooms[room.id] = room
        @by_key[key]    = room.id if key
        @dirty          = true
        room
      end

      # Record the traversal (from, direction, to). NEVER auto-create the
      # reverse edge (§6.7): a north from A to B does not imply a south from B
      # to A, and the difference between "confirmed both ways" and "seen one
      # way" is real information.
      #
      # `evidence: false` means "this edge is only a re-statement of the exits
      # line". An announcement establishes nothing about where the edge goes,
      # and both halves of a future split would announce it identically, so it
      # must not be recorded as evidence — otherwise every walked edge ends up
      # carrying an announcement seq from the merged node's first visit and
      # §6.5's split can never attribute anything.
      def record_edge(from:, direction:, to:, status: :open, seq:, requires: nil, evidence: true)
        edge = @edges[[from, direction]]

        if edge.nil?
          edge = Edge.new(from: from, direction: direction, to: to, status: status,
                          requires: requires, evidence: evidence ? [seq] : [], last_seq: seq)
          @edges[[from, direction]] = edge
          check_degree(from, direction, seq)
          @dirty = true
          return edge
        end

        # Edge invariant (§6.6): the same room and the same direction must
        # always lead to the same node. A violation is a wrong merge surfacing.
        if to && edge.to && edge.to != to
          violate!(:edge_conflict, seq,
                   "#{label(from)} #{direction} previously led to #{label(edge.to)}, now #{label(to)}")
        end

        edge.to        = to if to
        edge.status    = status unless status == :unknown && edge.status != :unknown
        edge.requires  = requires if requires
        edge.evidence << seq if evidence
        edge.last_seq  = seq
        @dirty         = true
        edge
      end

      # §6.7: `[ Exits: n e s w ]` tells you a room has four exits *before* you
      # have walked any of them. Recording each as an edge with to = unknown is
      # what turns "find location X" from wandering into a search with a real
      # frontier.
      def record_announced_exits(room, seq:)
        room.exits.each do |dir|
          existing = @edges[[room.id, dir]]
          if existing
            # A door that is announced shut is still an exit; keep the status
            # fresh but never downgrade a walked edge to :unknown.
            existing.status = :closed_door if room.doors.include?(dir) && existing.to.nil?
            next
          end
          record_edge(from: room.id, direction: dir, to: nil, seq: seq, evidence: false,
                      status: room.doors.include?(dir) ? :closed_door : :unknown)
        end
      end

      # The `exits` command named what is on the other side of an exit without
      # us walking it. Record the label; mint nothing. If the edge has already
      # been walked, the name is a check on what we recorded rather than news,
      # and a disagreement is worth surfacing — under the same corroboration
      # rule as #check_expectation, and for the same reason: a label naming no
      # room we have ever seen contradicts nothing, and deciding otherwise would
      # mean this code holding a list of one server's stock phrases.
      def record_expected(from:, direction:, title:, seq:)
        edge = @edges[[from, direction]] ||
               record_edge(from: from, direction: direction, to: nil, seq: seq,
                           status: :unknown, evidence: false)

        if edge.to && (known = @rooms[edge.to]) && !known.dark? && known.title != title &&
           title_index.key?(title)
          violate!(:destination_conflict, seq,
                   "#{label(from)} #{direction} was walked to #{known.title.inspect} " \
                   "but the exits listing names #{title.inspect}")
        end

        edge.expected_title = title
        edge.last_seq       = seq
        @dirty              = true
        edge
      end

      # We walked an edge the `exits` listing had already named. Arriving is
      # the observation that settles it.
      # A listed destination is a hypothesis, and walking it is the test. The
      # arrival is what goes on the map either way, so nothing here changes the
      # graph — the only question is whether a failed test is worth flagging.
      #
      # It is a violation only when the label names a room we have actually
      # stood in somewhere. Then two observations of our own disagree, which is
      # the thing violations exist to catch.
      #
      # When the label names nothing we have ever seen, we hold no belief for
      # the arrival to contradict. That covers the case where a server answers
      # with a sentence instead of a name because the way is dark or the door is
      # shut, and it covers it without this code knowing a single thing about
      # which sentences those are — which is the point. Encoding tbaMUD's
      # wording here would be a list that is silently wrong on the next MUD.
      def check_expectation(edge, room, seq)
        return if edge.expected_title.nil? || room.dark?
        return if edge.expected_title == room.title
        return unless title_index.key?(edge.expected_title)

        violate!(:destination_conflict, seq,
                 "#{label(edge.from)} #{edge.direction} was listed as leading to " \
                 "#{edge.expected_title.inspect} but walking it arrived in #{room.title.inspect}")
      end

      def mark_exits_listed(room, seq)
        room.listed_seq = seq
        @dirty = true
        room
      end

      def edge(from, direction) = @edges[[from, direction]]

      # Frontier edges whose destination has been named but never walked. These
      # are routable targets: we know what is there without having been there.
      def named_frontier_edges
        @edges.values.select { |e| e.frontier? && e.expected_title }
      end

      # title => [room ids]. A search index in the sense of §6.1: derived from
      # the rooms, rebuilt on demand, never a second source of truth. It is what
      # lets a listed destination name be resolved to a node at search time
      # rather than being frozen into the stored map, so it cannot go stale when
      # a room is minted, absorbed or split.
      def title_index
        idx = Hash.new { |h, k| h[k] = [] }
        @rooms.each_value { |r| idx[r.title] << r.id unless r.dark? }
        idx
      end

      def edges_from(id) = @edges.values.select { |e| e.from == id }

      def edges_to(id) = @edges.values.select { |e| e.to == id }

      # Every exit we have never actually attempted. This is the exploration
      # plan; without it, exploration has no plan at all.
      #
      # "Never attempted" is exactly `evidence.empty?`: an announcement from the
      # exits line records no evidence, while a traversal, successful or
      # refused, records the observation sequence. So a door announced shut is
      # still worth one try, and stops being worth trying the moment that try
      # comes back refused.
      #
      # This used to be every unwalked edge, which meant a direction the game
      # had flatly rejected stayed on the to-try list forever and exploration
      # could never terminate.
      def frontier_edges
        @edges.values.select(&:untried?)
      end

      # Everything never walked, whatever we have learned about it. Used for
      # reporting rather than for planning.
      def unwalked_edges = @edges.values.select(&:frontier?)

      # ── reversibility (§6.5) ────────────────────────────────────────────────

      # A wrong merge is discovered late, by contradiction, so the projection
      # has to be able to take a node back apart — not only join. Every edge
      # records the observation sequence that established it, which is exactly
      # what lets its edges be reassigned to the right side of a split.
      #
      # Returns the new Room, which inherits every edge whose evidence lies at
      # or after `from_seq`. Without this a single bad merge is permanent and
      # silently poisons every path through that room.
      def split(room_id, from_seq:)
        old = @rooms.fetch(room_id)
        neu = mint(key: nil, title: old.title, description: old.description,
                   exits: old.exits.dup, doors: old.doors.dup,
                   coords: old.coords, seq: from_seq, flags: old.flags.dup)

        # The old room keeps the key; the split-off copy is keyless until it is
        # observed again, so it can never silently re-absorb arrivals.
        #
        # An edge moves only when every traversal that established it happened
        # at or after the split point. An edge walked on both sides of it is
        # genuinely ambiguous and stays put — split makes the merge reversible,
        # it does not pretend to know which half an old traversal belonged to.
        @edges.values.to_a.each do |e|
          next if e.evidence.empty?
          next unless e.evidence.all? { |s| s >= from_seq }
          if e.from == room_id
            @edges.delete([e.from, e.direction])
            e.from = neu.id
            @edges[[e.from, e.direction]] = e
          end
          e.to = neu.id if e.to == room_id
        end

        # Both halves announce the same exits. The new node needs its own
        # frontier, and the original needs back any exit whose walked edge just
        # left with the split — it still announces that exit, it just no longer
        # knows where it goes.
        record_announced_exits(neu, seq: from_seq)
        record_announced_exits(old, seq: from_seq)

        @position = neu.id if @position == room_id
        @dirty    = true
        neu
      end

      # ── invariants (§6.6) ───────────────────────────────────────────────────

      # Verification is self-derived. No world file is ever read (§8.2): the
      # map is checked against itself and against the game, using only what the
      # agent observed by walking.
      #
      # The edge and exit-set invariants are enforced at record time (they need
      # the incoming observation to compare against). The degree invariant is a
      # standing property of the stored map, so it is re-derivable at any time.
      # Read-only: it reports, it does not append to the violation log.
      def audit
        found = []
        @rooms.each_value do |room|
          next if room.exits.empty?
          extra = edges_from(room.id).map(&:direction) - room.exits
          next if extra.empty?
          found << { "kind" => "degree", "seq" => room.last_seq,
                     "message" => "#{label(room.id)} announces #{room.exits.join(',')} " \
                                  "but has edges #{extra.join(',')}" }
        end
        found
      end

      def coords_for(from_id, direction)
        base = from_id && @rooms[from_id]&.coords
        return nil unless base
        d = DELTA[direction] or return nil
        [base[0] + d[0], base[1] + d[1], base[2] + d[2]]
      end

      def label(id)
        r = @rooms[id]
        r ? "#{r.title} <#{id[0, 8]}>" : "<unknown>"
      end

      # ── serialization ───────────────────────────────────────────────────────

      def to_h
        {
          "version"    => 1,
          "seq"        => @seq,
          "position"   => @position,
          "rooms"      => @rooms.values.map { |r| r.to_h.transform_keys(&:to_s) },
          "edges"      => @edges.values.map { |e| e.to_h.transform_keys(&:to_s).merge("status" => e.status.to_s) },
          "violations" => @violations
        }
      end

      def self.from_h(data)
        w = new
        return w unless data.is_a?(Hash)
        w.seq      = data["seq"].to_i
        Array(data["rooms"]).each { |r| w.send(:load_room, r) }
        Array(data["edges"]).each { |e| w.send(:load_edge, e) }
        w.position   = data["position"]
        w.violations.concat(Array(data["violations"]))
        w.clean!
        w
      end

      private

      def load_room(h)
        room = Room.new(
          id: h["id"], key: h["key"], title: h["title"], description: h["description"],
          exits: Array(h["exits"]), doors: Array(h["doors"]), coords: h["coords"],
          flags: Array(h["flags"]), first_seq: h["first_seq"], last_seq: h["last_seq"],
          listed_seq: h["listed_seq"]
        )
        @rooms[room.id] = room
        @by_key[room.key] = room.id if room.key
      end

      def load_edge(h)
        edge = Edge.new(from: h["from"], direction: h["direction"], to: h["to"],
                        status: h["status"].to_sym, requires: h["requires"],
                        expected_title: h["expected_title"],
                        evidence: Array(h["evidence"]), last_seq: h["last_seq"])
        @edges[[edge.from, edge.direction]] = edge
      end

      # Exit-set invariant (§6.6): revisiting a node must observe the exit set
      # already recorded for it. Doors may open and shut freely — a shut door
      # is still listed as an exit — so only the exit *set* is invariant.
      #
      # On a mismatch we do NOT union the two sets. A union is a room that was
      # never observed: it asserts exits no single look ever showed, and it
      # quietly buries the contradiction it was just handed. Both sets are real
      # observations, and the likeliest reason they disagree is §6.4 — two
      # genuinely different rooms sharing a title and a description, wrongly
      # merged. So record the conflict, flag the room, and keep the set we most
      # recently saw. The stale edges then show up in the degree audit, which
      # is the same contradiction seen from the other side, and §6.5's split is
      # how it gets undone.
      def merge_into(room, obs, seq)
        if room.exits.sort != obs.exits.sort
          violate!(:exit_set, seq,
                   "#{label(room.id)} was #{room.exits.join(',')}, now #{obs.exits.join(',')} " \
                   "— suspected wrong merge, needs a confirming walk")
          room.flags     |= ["suspect_merge"]
          room.exits      = obs.exits
          # The exit set moved, so whatever the last listing said about this
          # room is no longer something we have observed to be current.
          room.listed_seq = nil
        end
        room.doors    = obs.doors
        room.last_seq = seq
        @dirty        = true
        room
      end

      def touch(room, seq)
        room.last_seq = seq
        @dirty = true
        room
      end

      def check_degree(from, direction, seq)
        room = @rooms[from] or return
        return if room.exits.empty? || room.exits.include?(direction)
        violate!(:degree, seq,
                 "#{label(from)} announces #{room.exits.join(',')} but grew an edge #{direction}")
      end

      def violate!(kind, seq, message)
        @violations << { "kind" => kind.to_s, "seq" => seq, "message" => message }
        @dirty = true
      end
    end
  end
end
