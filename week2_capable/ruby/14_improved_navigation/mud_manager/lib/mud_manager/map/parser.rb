require_relative "observation"

module MudManager
  module Map
    # Parser turns one MUD response into an Observation.
    #
    # It anchors on ANSI colour, per §5 of the epic. The colour codes are
    # structure, not noise, and two of them delimit the room block exactly:
    #
    #   ESC[0;33m  yellow  the room title  (104 of 105 room observations)
    #   ESC[0;36m  cyan    the [ Exits: ]  (105 of 105)
    #
    # So: the title is the first yellow line, the exits are the cyan line, the
    # description is everything between them, and mobs and objects are
    # everything after. Stripping ANSI *before* parsing throws away the most
    # reliable signal on the screen — mobs are yellow too, and are told apart
    # from the title only by falling below the exits line.
    #
    # Closed doors are pre-announced in the exits line as a parenthesised,
    # red-coloured direction: `[ Exits: n s (w) ]`. So an edge can be marked
    # door-bearing before it is ever walked.
    module Parser
      TITLE_COLOR = "\e[0;33m".freeze
      EXITS_COLOR = "\e[0;36m".freeze
      ANSI        = /\e\[[0-9;]*m/.freeze

      EXITS_LINE = /\[\s*Exits:\s*(?<body>[^\]]*)\]/.freeze

      # The `exits` command (INFO_SELF, so `check kind: exits`). Unlike the
      # `[ Exits: ]` line, which gives only the direction set, this names the
      # room on the other side of each one:
      #
      #   Obvious exits:
      #   north - By The Temple Altar
      #   east  - The Midgaard Donation Room
      #
      # It carries no colour codes at all, so it is recognised by its header.
      EXIT_LIST_HEADER = /^\s*Obvious exits:/.freeze
      EXIT_LIST_ENTRY  = /^\s*(north|east|south|west|up|down)\s+-\s+(\S.*?)\s*$/i.freeze
      # The listing does not always name a room. Where the doorway is shut, or
      # the room beyond is unlit, tbaMUD puts a sentence in the title's place
      # ("Too dark to tell.", "The door is closed."). The parser reports those
      # verbatim like any other label and does not try to recognise them: which
      # sentences a given server substitutes is not knowable from here, and a
      # list of them would be a list that is wrong on the next MUD. What the
      # label MEANS is settled downstream, by walking it.
      # The CircleMUD status prompt is embedded in every response (§5, "free
      # state"): `25H 100M 80V >`.
      PROMPT     = /(?<hp>\d+)H\s+(?<mana>\d+)M\s+(?<move>\d+)V\s*>/.freeze
      PITCH_BLACK = /It is pitch black\.\.\./.freeze

      ABBREV = {
        "n" => "north", "e" => "east", "s" => "south",
        "w" => "west",  "u" => "up",   "d" => "down"
      }.freeze

      # These two are observed in the corpus and they are an OPTIMISATION, not
      # the mechanism: matching one names the reason for a refusal in the same
      # round trip, which is worth a little to the cost model. Matching nothing
      # is not a failure — Cartographer#settle then establishes whether the move
      # worked by looking, which is what actually makes this work on a MUD whose
      # wording nobody here has seen.
      #
      # The table stays short and stays honest for that reason. It used to carry
      # three more patterns that were guesses at wording never once observed;
      # measured against the corpus they classified nothing, while the replies
      # that DID occur ("You are too exhausted.", "This zone is above your
      # recommended level.") were not in it. Guessing at a server's phrasing is
      # not a strategy that converges.
      REFUSALS = [
        [/The door seems to be closed\./, :closed_door],
        [/You need a boat to go there\./, :needs_boat]
      ].freeze

      module_function

      def parse(text)
        raw    = text.to_s
        lines  = raw.split("\n").map { |l| l.chomp("\r") }
        vitals = parse_vitals(raw)

        exits_idx = lines.index { |l| l.include?(EXITS_COLOR) && l =~ EXITS_LINE } ||
                    lines.index { |l| l =~ EXITS_LINE }

        return parse_room(lines, exits_idx, vitals, raw) if exits_idx

        header = lines.index { |l| strip_ansi(l) =~ EXIT_LIST_HEADER }
        return parse_exit_list(lines, header, vitals, raw) if header

        if raw =~ PITCH_BLACK
          return Observation.new(kind: :dark, vitals: vitals, verified: true, text: raw)
        end

        REFUSALS.each do |pattern, reason|
          next unless raw =~ pattern
          return Observation.new(kind: :refused, reason: reason, vitals: vitals,
                                 verified: true, text: raw)
        end

        Observation.new(kind: :unparsed, vitals: vitals, verified: true, text: raw)
      end

      # ── internals ───────────────────────────────────────────────────────────

      def parse_room(lines, exits_idx, vitals, raw)
        head = lines[0...exits_idx]

        # The title is the first yellow line above the exits. One room in 105
        # arrived without the colour code, so fall back to the first non-blank
        # line rather than failing to identify the room at all.
        title_idx = head.index { |l| l.include?(TITLE_COLOR) } ||
                    head.index { |l| !strip_ansi(l).strip.empty? }
        return Observation.new(kind: :unparsed, vitals: vitals, verified: true, text: raw) unless title_idx

        title = strip_ansi(head[title_idx]).strip
        desc  = normalize_description(head[(title_idx + 1)..] || [])
        exits, doors = parse_exits(lines[exits_idx])

        Observation.new(kind: :room, title: title, description: desc,
                        exits: exits, doors: doors, vitals: vitals,
                        verified: true, text: raw)
      end

      # Only what is on the screen is recorded. In particular, a direction that
      # the `[ Exits: ]` line announced but that this listing omits is NOT
      # inferred to be anything: we have never observed what the `exits`
      # command does with a shut door, so nothing is concluded from an absence.
      def parse_exit_list(lines, header, vitals, raw)
        dests = {}
        lines[(header + 1)..].to_a.each do |line|
          m = strip_ansi(line).match(EXIT_LIST_ENTRY) or next
          dests[m[1].downcase] = m[2]
        end
        Observation.new(kind: :exit_list, destinations: dests, vitals: vitals,
                        verified: true, text: raw)
      end

      # `[ Exits: n s (w) ]` -> [["north","south","west"], ["west"]]
      def parse_exits(line)
        body  = strip_ansi(line)[EXITS_LINE, :body].to_s
        exits = []
        doors = []
        body.scan(/\(?\s*([neswud])\s*\)?/i) do
          token = Regexp.last_match(0)
          dir   = ABBREV[Regexp.last_match(1).downcase]
          next unless dir
          exits << dir
          doors << dir if token.include?("(")
        end
        [exits.uniq, doors.uniq]
      end

      # §6.2 rests on descriptions being byte-stable across visits (21 of 23
      # repeat-visited titles were byte-identical every time). Normalizing
      # trailing whitespace and blank edges makes that robust to line-ending
      # and padding drift without weakening the key.
      def normalize_description(lines)
        body = lines.map { |l| strip_ansi(l).rstrip }
        body.shift while body.first && body.first.empty?
        body.pop   while body.last  && body.last.empty?
        body.join("\n")
      end

      def parse_vitals(raw)
        m = nil
        raw.to_s.scan(PROMPT) { m = Regexp.last_match }
        return nil unless m
        { "hp" => m[:hp].to_i, "mana" => m[:mana].to_i, "move" => m[:move].to_i }
      end

      def strip_ansi(str) = str.to_s.gsub(ANSI, "")
    end
  end
end
