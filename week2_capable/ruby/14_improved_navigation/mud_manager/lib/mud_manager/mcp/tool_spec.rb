require_relative "../primitives"

module MudManager
  module Mcp
    # ToolSpec is the *single Ruby source of truth* for the gameplay tool
    # surface exposed by the mud-manager daemon (both the MCP facade and the
    # raw JSON-line protocol). It began as a 1:1 mirror of the tools that
    # Boukensha::Tools::Mud registered in-process; that module is gone (boukensha
    # owns no tools now), so this table is the only definition of the surface
    # left. Here they are declarative data instead of imperative registry calls,
    # so we can:
    #
    #   * render them as MCP tool schemas (tools/list),
    #   * dispatch a (name, args) pair to a MudManager::Primitives::Command,
    #   * and generate primitives.json (see Spec.dump) for any *other* language
    #     track that wants local typed builders.
    #
    # Enum value lists are pulled *live* from MudManager::Primitives constants
    # (DIRECTIONS, ATTACK_STYLES, …). Ruby is canonical, exactly as decided in
    # the plan: if the gem changes an enum, every consumer of primitives.json
    # inherits the change on the next dump — the two can never drift.
    #
    # Each tool descriptor is a Hash:
    #
    #   name:        tool name (String)
    #   category:    grouping label (String)
    #   description: LLM-facing help text (String)
    #   mode:        :primitive | :raw | :poll | :status  (how the server executes it)
    #   params:      ordered Hash of param-name => descriptor
    #                  { type:, description:, required:, enum:, default: }
    #   build:       Proc(args_hash) -> MudManager::Primitives::Command
    #                (only for mode: :primitive; args keyed by String)
    #
    module ToolSpec
      P = MudManager::Primitives

      # A small helper so param descriptors read cleanly below.
      def self.param(type:, description:, required: false, enum: nil, default: nil)
        d = { type: type, description: description, required: required }
        d[:enum]    = enum    unless enum.nil?
        d[:default] = default unless default.nil?
        d
      end

      # Normalize an incoming argument value: treat blank strings as absent so
      # that JSON clients that always send every key (with "") behave like
      # clients that omit optional keys.
      def self.present(v)
        return nil if v.nil?
        s = v.to_s
        s.strip.empty? ? nil : v
      end

      # The full ordered tool table. Built lazily so the Primitives constants
      # are resolved at call time (and so tests can reload cleanly).
      def self.all
        @all ||= build_all
      end

      def self.find(name)
        all.find { |t| t[:name] == name.to_s }
      end

      def self.build_all
        pr = method(:param)
        [
          # ── Perception ────────────────────────────────────────────────────
          {
            name: "look", category: "perception", mode: :primitive,
            description:
              "Look at the current room or at a specific target. Call with NO " \
              "arguments to describe the current room (do NOT pass target: 'room'). " \
              "Pass a target to inspect a specific item, mob, or player. Use " \
              "preposition 'in' to look inside a container, 'at' to inspect, or a " \
              "direction to peek into an adjacent room.",
            params: {
              "target"      => pr.(type: "string", description: "Item, mob, or player to inspect. Omit to describe the current room."),
              "preposition" => pr.(type: "string", description: "Preposition or direction to look through.", enum: P::LOOK_PREPS)
            },
            build: ->(a) { P.look(target: present(a["target"]), preposition: present(a["preposition"])) }
          },
          {
            name: "examine", category: "perception", mode: :primitive,
            description: "Examine a target in detail (more verbose than look).",
            params: {
              "target" => pr.(type: "string", description: "The item, mob, or player to examine", required: true)
            },
            build: ->(a) { P.examine(a["target"]) }
          },
          {
            name: "check", category: "perception", mode: :primitive,
            description: "Query information about your character or surroundings.",
            params: {
              "kind" => pr.(type: "string", description: "What to check", required: true, enum: P::INFO_SELF)
            },
            build: ->(a) { P.info_self(a["kind"]) }
          },

          # ── Movement ──────────────────────────────────────────────────────
          {
            name: "move", category: "movement", mode: :primitive,
            description: "Move in a compass direction or up/down.",
            params: {
              "direction" => pr.(type: "string", description: "Direction to move", required: true, enum: P::DIRECTIONS)
            },
            build: ->(a) { P.move(a["direction"]) }
          },
          {
            name: "flee", category: "movement", mode: :primitive,
            description: "Attempt to flee from combat in a random available direction.",
            params: {},
            build: ->(_a) { P.flee }
          },
          {
            name: "set_position", category: "movement", mode: :primitive,
            description: "Change body position. Use 'rest'/'sleep' between fights to recover HP and mana. Must be standing to move or fight.",
            params: {
              "position" => pr.(type: "string", description: "Body position", required: true, enum: P::POSITIONS)
            },
            build: ->(a) { P.set_position(a["position"]) }
          },
          {
            name: "track", category: "movement", mode: :primitive,
            description: "Track a mob or player by name, revealing their direction. Requires the Track skill.",
            params: {
              "target" => pr.(type: "string", description: "Name of the mob or player to track", required: true)
            },
            build: ->(a) { P.track(a["target"]) }
          },

          # ── Combat ────────────────────────────────────────────────────────
          {
            name: "attack", category: "combat", mode: :primitive,
            description: "Attack a target. 'kill' is standard; 'murder' bypasses the mercy check; 'hit' is a one-off strike.",
            params: {
              "target" => pr.(type: "string", description: "Name of the mob or player to attack", required: true),
              "style"  => pr.(type: "string", description: "Attack style", enum: P::ATTACK_STYLES, default: "kill")
            },
            build: ->(a) { P.attack(present(a["style"]) || "kill", a["target"]) }
          },
          {
            name: "skill_strike", category: "combat", mode: :primitive,
            description: "Use a combat skill against a target.",
            params: {
              "skill"  => pr.(type: "string", description: "Combat skill", required: true, enum: P::STRIKE_SKILLS),
              "target" => pr.(type: "string", description: "Name of the mob or player", required: true)
            },
            build: ->(a) { P.skill_strike(a["skill"], a["target"]) }
          },
          {
            name: "consider", category: "combat", mode: :primitive,
            description: "Assess a mob's relative strength before fighting. Always consider before attacking an unknown mob.",
            params: {
              "target" => pr.(type: "string", description: "Name of the mob to consider", required: true)
            },
            build: ->(a) { P.consider(a["target"]) }
          },

          # ── Communication ─────────────────────────────────────────────────
          {
            name: "say", category: "communication", mode: :primitive,
            description: "Speak or emote in the current room.",
            params: {
              "text" => pr.(type: "string", description: "What to say or emote", required: true),
              "mode" => pr.(type: "string", description: "Speech mode", enum: P::LOCAL_SAY, default: "say")
            },
            build: ->(a) { P.say_local(present(a["mode"]) || "say", a["text"]) }
          },
          {
            name: "tell", category: "communication", mode: :primitive,
            description: "Send a private message to a specific player.",
            params: {
              "target" => pr.(type: "string", description: "Player name to message", required: true),
              "text"   => pr.(type: "string", description: "The message", required: true),
              "mode"   => pr.(type: "string", description: "Tell mode", enum: P::TARGETED_SAY, default: "tell")
            },
            build: ->(a) { P.say_targeted(present(a["mode"]) || "tell", a["target"], a["text"]) }
          },
          {
            name: "channel_say", category: "communication", mode: :primitive,
            description: "Broadcast a message over a global channel.",
            params: {
              "channel" => pr.(type: "string", description: "Channel", required: true, enum: P::CHANNELS),
              "text"    => pr.(type: "string", description: "The message to broadcast", required: true)
            },
            build: ->(a) { P.say_channel(a["channel"], a["text"]) }
          },

          # ── Inventory & equipment ─────────────────────────────────────────
          {
            name: "get_item", category: "inventory", mode: :primitive,
            description: "Pick up an item from the room or from a container.",
            params: {
              "item"      => pr.(type: "string",  description: "Name of the item to get", required: true),
              "container" => pr.(type: "string",  description: "Container to get it from (optional)"),
              "count"     => pr.(type: "integer", description: "Number of items to get (optional)")
            },
            build: ->(a) { P.get(a["item"], container: present(a["container"]), count: present(a["count"])) }
          },
          {
            name: "drop_item", category: "inventory", mode: :primitive,
            description: "Drop, donate, or junk an item.",
            params: {
              "item"  => pr.(type: "string",  description: "Name of the item", required: true),
              "mode"  => pr.(type: "string",  description: "Drop mode", enum: P::DROP_MODES, default: "drop"),
              "count" => pr.(type: "integer", description: "Number of items (optional)")
            },
            build: ->(a) { P.drop(present(a["mode"]) || "drop", a["item"], count: present(a["count"])) }
          },
          {
            name: "put_item", category: "inventory", mode: :primitive,
            description: "Put an item into a container.",
            params: {
              "item"      => pr.(type: "string",  description: "Name of the item to put", required: true),
              "container" => pr.(type: "string",  description: "Name of the container", required: true),
              "count"     => pr.(type: "integer", description: "Number of items (optional)")
            },
            build: ->(a) { P.put(a["item"], a["container"], count: present(a["count"])) }
          },
          {
            name: "equip_item", category: "inventory", mode: :primitive,
            description: "Wear, wield, hold, grab, or remove an item.",
            params: {
              "item"     => pr.(type: "string", description: "Name of the item", required: true),
              "action"   => pr.(type: "string", description: "Equip action", required: true, enum: P::EQUIP_OPS),
              "body_loc" => pr.(type: "string", description: "Body location to wear on (optional, e.g. 'head', 'finger')")
            },
            build: ->(a) { P.equip(a["action"], a["item"], body_loc: present(a["body_loc"])) }
          },
          {
            name: "consume_item", category: "inventory", mode: :primitive,
            description: "Eat, drink, taste, or sip a consumable item.",
            params: {
              "item" => pr.(type: "string", description: "Name of the item to consume", required: true),
              "mode" => pr.(type: "string", description: "Consume mode", enum: P::CONSUME_MODES, default: "eat")
            },
            build: ->(a) { P.consume(present(a["mode"]) || "eat", a["item"]) }
          },

          # ── Magic ─────────────────────────────────────────────────────────
          {
            name: "cast_spell", category: "magic", mode: :primitive,
            description: "Cast a spell, optionally at a target.",
            params: {
              "spell"  => pr.(type: "string", description: "Full spell name (e.g. 'cure light wounds')", required: true),
              "target" => pr.(type: "string", description: "Target mob, player, or object (optional)")
            },
            build: ->(a) { P.cast(a["spell"], target: present(a["target"])) }
          },
          {
            name: "use_magic_item", category: "magic", mode: :primitive,
            description: "Activate a magic item: quaff a potion, recite a scroll, or use a wand/staff.",
            params: {
              "item"        => pr.(type: "string", description: "Name of the item to activate", required: true),
              "mode"        => pr.(type: "string", description: "Activation mode", required: true, enum: P::SPELL_ITEM),
              "target_args" => pr.(type: "string", description: "Optional target arguments (e.g. mob name for a wand)")
            },
            build: ->(a) { P.use_magic_item(a["mode"], a["item"], target_args: present(a["target_args"])) }
          },

          # ── Utility ───────────────────────────────────────────────────────
          {
            name: "shop", category: "utility", mode: :primitive,
            description: "Interact with a shop NPC: list stock, buy, sell, or value an item.",
            params: {
              "action" => pr.(type: "string", description: "Shop action", required: true, enum: P::SHOP_OPS),
              "args"   => pr.(type: "string", description: "Item name or number (optional)")
            },
            build: ->(a) { P.shop(a["action"], args: present(a["args"])) }
          },
          {
            name: "practice", category: "utility", mode: :primitive,
            description: "List your known skills at a guildmaster, or practice a specific skill.",
            params: {
              "skill" => pr.(type: "string", description: "Skill name to practice (omit to list all)")
            },
            build: ->(a) { P.practice(present(a["skill"])) }
          },
          {
            name: "save_character", category: "utility", mode: :primitive,
            description: "Save your character to disk so progress is not lost on disconnect.",
            params: {},
            build: ->(_a) { P.save_char }
          },
          {
            name: "send_raw", category: "utility", mode: :raw,
            description: "Send an arbitrary command string to the MUD and return the response. " \
                         "Escape hatch for when no structured tool fits.",
            params: {
              "command" => pr.(type: "string", description: "The raw command to send (e.g. 'who', 'help backstab')", required: true)
            }
            # no build: mode :raw sends command["command"] verbatim
          },

          # ── Async / status (daemon additions, per plan §5 and open-Q #2) ──
          {
            name: "poll", category: "utility", mode: :poll,
            description: "Return any unprompted output that has arrived since the last command " \
                         "(combat ticks, other players, room events) without sending anything. " \
                         "Use this to notice things that happen while idle.",
            params: {}
          },
          {
            name: "mud_status", category: "utility", mode: :status,
            description: "Report whether the MUD session is currently connected.",
            params: {}
          },

          # ── The map (epic 14, §9.1) ───────────────────────────────────────
          #
          # The map lives in this server because ADR 0012 is unambiguous:
          # boukensha ships no tools and every capability comes from an MCP
          # server. This server also already executes the move, so it has the
          # direction and the result in one place.
          #
          # Three tools, deliberately. Each schema costs roughly 143 tokens on
          # every single call against a median 15,001-token call, and F23
          # deleted a whole server over exactly this. The map itself is never
          # put in context — the agent asks a question and gets a short answer.
          {
            name: "map_where", category: "navigation", mode: :map,
            description:
              "Where am I? Looks at the current room, matches it against the map built from " \
              "previous exploration, and reports the room name, which exits lead to rooms " \
              "you already know, and which are still unexplored — including, where the game " \
              "has told us, the name of the room behind an exit nobody has walked yet. Call " \
              "this first in a session, or any time a move goes wrong and you are unsure of " \
              "your position.",
            params: {}
          },
          {
            name: "map_goto", category: "navigation", mode: :map,
            description:
              "Walk to a room by name (e.g. 'bakery', 'temple'). Works for rooms you have " \
              "visited AND for rooms the game has named as lying through an exit you have " \
              "not walked yet. Finds the shortest route through the map, walks the whole way " \
              "in one call, and routes around doors and obstacles it has learned about. " \
              "ALWAYS prefer this over a sequence of move calls when you know where you want " \
              "to go — it is one call instead of one per step.",
            params: {
              "destination" => pr.(type: "string", description: "Room name or part of one, e.g. 'market square'", required: true)
            }
          },
          {
            name: "map_explore", category: "navigation", mode: :map,
            description:
              "Expand the map: walk to the nearest exit that has never been tried and take " \
              "it. Use this instead of guessing directions when you are looking for " \
              "somewhere you have not been. Reports what was found and how many unexplored " \
              "exits remain.",
            params: {}
          }
        ]
      end
      private_class_method :build_all
    end
  end
end
