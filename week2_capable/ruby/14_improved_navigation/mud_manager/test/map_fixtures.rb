# Screen text exactly as tbaMUD emits it, taken from the two recorded sessions
# that carry the 99 moves of the corpus (§7.2 of the epic).
#
# The ANSI codes are part of the fixture, not decoration. §5: the title is the
# first ESC[0;33m line, the exits are the ESC[0;36m line, the description is
# everything between them, and mobs and objects are everything after. Mobs are
# yellow too, which is precisely why a test that strips colour first would pass
# while the parser it is testing could not tell a mob from a room title.
#
# Nothing here comes from a world file (§8.2). These are transcripts of a
# player walking around.
module MapFixtures
  Y = "\e[0;33m".freeze   # yellow — room titles (and mobs)
  C = "\e[0;36m".freeze   # cyan   — the exits line
  R = "\e[0;31m".freeze   # red    — a parenthesised, i.e. shut, door
  G = "\e[0;32m".freeze   # green  — objects
  O = "\e[0m".freeze

  module_function

  def crlf(lines) = lines.map { |l| "#{l}\r" }.join("\n")

  TEMPLE_SQUARE = crlf([
    "#{Y}The Temple Square#{O}",
    "   You are standing on the temple square.  Huge marble steps lead up to the",
    "temple gate.  The entrance to the Clerics' Guild is to the west, and the old",
    "Grunting Boar Inn, is to the east.  Just south of here you see the market",
    "square, the center of Midgaard.",
    "#{C}[ Exits: n e s w ]#{O}",
    "#{G}#{G}A large fountain carved from blue-streaked marble is here, bubbling merrily.",
    "#{O}",
    "25H 100M 83V > "
  ])

  MARKET_SQUARE = crlf([
    "#{Y}Market Square#{O}",
    "   You are standing on the market square, the famous Square of Midgaard.",
    "A large, peculiar looking statue is standing in the middle of the square.",
    "Roads lead in every direction, north to the temple square, south to the",
    "common square, east and westbound is the main street.",
    "#{C}[ Exits: n e s w ]#{O}",
    "",
    "25H 100M 82V > "
  ])

  # The same room with mobs below the exits line. Mobs are yellow, so this is
  # the fixture that catches a parser which takes the *last* yellow line, or
  # which strips ANSI before deciding what the title is.
  COMMON_SQUARE = crlf([
    "#{Y}The Common Square#{O}",
    "   The common square, people pass you, talking to each other.  To the west is",
    "the poor alley and to the east is the dark alley.  To the north, this square",
    "is connected to the market square.  From the south you notice a nasty smell.",
    "#{C}[ Exits: n e s w ]#{O}",
    "#{Y}A beastly fido is mucking through the garbage looking for food here.",
    "#{O}#{Y}A beastly fido is mucking through the garbage looking for food here.",
    "#{O}",
    "25H 100M 81V > "
  ])

  # Two of the three physically distinct rooms tbaMUD calls "Main Street".
  # §6.2: the title is a strong recognition signal but not a key on its own;
  # the description is what separates them.
  MAIN_STREET_A = crlf([
    "#{Y}Main Street#{O}",
    "   You are walking on Main Street, the west end.  The street continues",
    "east toward the market square.",
    "#{C}[ Exits: e w ]#{O}",
    "",
    "25H 100M 80V > "
  ])

  MAIN_STREET_B = crlf([
    "#{Y}Main Street#{O}",
    "   You are walking on Main Street, the east end.  The street continues",
    "west toward the market square.",
    "#{C}[ Exits: e w ]#{O}",
    "",
    "25H 100M 79V > "
  ])

  # Closed doors are pre-announced in the exits line as a parenthesised, red
  # direction — so an edge can be marked door-bearing before it is ever walked.
  DOORED_ROOM = crlf([
    "#{Y}The Reading Room#{O}",
    "   Bookshelves line the walls of this quiet room.",
    "#{C}[ Exits: n s #{R}(w)#{C} ]#{O}",
    "",
    "25H 100M 78V > "
  ])

  ALL_DOORS = crlf([
    "#{Y}The Vestibule#{O}",
    "   A small entryway.",
    "#{C}[ Exits: #{R}(n)#{C} #{R}(e)#{C} s w ]#{O}",
    "",
    "25H 100M 77V > "
  ])

  # A room reached by going down; proves the direction set is the full six.
  CELLAR = crlf([
    "#{Y}A Dusty Cellar#{O}",
    "   Cobwebs and crates.",
    "#{C}[ Exits: n d ]#{O}",
    "",
    "25H 100M 76V > "
  ])

  # The three replies that carry no exits line. §5.1: these five results are
  # exactly the five moves in the corpus without one, so every recorded move is
  # classifiable and nothing is unexplained.
  PITCH_BLACK  = crlf(["It is pitch black...", "", "25H 100M 80V > "])
  CLOSED_DOOR  = crlf(["The door seems to be closed.", "", "25H 100M 80V > "])
  NEEDS_BOAT   = crlf(["You need a boat to go there.", "", "25H 100M 81V > "])

  # Not in the corpus, and its exact wording is unverified (§5.1). The parser
  # must not treat an unrecognised reply as a successful move.
  UNKNOWN_REPLY = crlf(["The gods frown upon your impertinence.", "", "25H 100M 81V > "])

  # The `exits` command. Unlike the `[ Exits: ]` line, which gives only the
  # direction set, this names the room on the other side of each one, without
  # moving. Verbatim from a live tbaMUD session. Note that `south` and `down`
  # both claim "The Temple Square", which is why a listed name labels the edge
  # and never becomes a room key.
  EXIT_LISTING = crlf([
    "Obvious exits:",
    "north - By The Temple Altar",
    "east  - The Midgaard Donation Room",
    "south - The Temple Square",
    "west  - The Reading Room",
    "down  - The Temple Square",
    "",
    "25H 100M 84V > "
  ])

  # The same listing with an async broadcast arriving after the prompt, which
  # is what actually happens when someone logs in nearby. It is the same hazard
  # as the Mayor line in §5: unrelated text inside an observation, skipped
  # because it does not look like anything the parser is anchored on.
  EXIT_LISTING_WITH_BROADCAST = crlf([
    "Obvious exits:",
    "north - By The Temple Altar",
    "east  - The Midgaard Donation Room",
    "south - The Temple Square",
    "west  - The Reading Room",
    "down  - The Temple Square",
    "",
    "25H 100M 84V > ",
    "A booming voice announces, 'Welcome Dummy to the realm!'"
  ])

  # From the corpus: a room with only two exits listed.
  EXIT_LISTING_SHORT = crlf([
    "Obvious exits:",
    "north - The Dark Alley At The Levee",
    "south - On The River",
    "",
    "25H 100M 84V > "
  ])

  # An async broadcast arriving with no colour code at all, which is why §5's
  # colour anchors skip it rather than needing a speech heuristic.
  MAYOR = "The Mayor says 'Good day, citizens!'\r\n"
end
