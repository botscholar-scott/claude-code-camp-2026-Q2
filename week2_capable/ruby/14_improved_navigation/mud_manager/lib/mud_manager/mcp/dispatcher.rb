require_relative "tool_spec"
require_relative "session_pool"
require_relative "errors"
require_relative "../map"

module MudManager
  module Mcp
    # Dispatcher is the seam between "a named tool with arguments" and "text
    # sent to / read from a session". It is transport-agnostic: both the MCP
    # facade and the raw JSON-line protocol call #call and get back a plain
    # String (or a ProtocolError is raised, carrying a structured code).
    #
    # This is exactly the work Boukensha::Tools::Mud's `send_cmd` lambda used to
    # do — drain → send → read — lifted out of the framework so every language
    # track inherits it for free. Ruby included: that module has since been
    # deleted, and boukensha drives this daemon over MCP like everyone else.
    #
    # Since epic 14 it is also where the map sees the world. Every gameplay
    # result passes through one point that has the tool name, the arguments and
    # the response together, which is why §9.1 puts the map here: nothing needs
    # to tail a log, correlate by position, or sit in the path as a proxy.
    class Dispatcher
      def initialize(pool, map_dir: nil)
        @pool          = pool
        @map_dir       = map_dir
        @cartographers = {}
        @mu            = Mutex.new
      end

      # name: tool name String; args: Hash with String keys; id: session id.
      # Returns the response text. Raises ProtocolError on any failure.
      def call(name, args = {}, id: "default")
        tool = ToolSpec.find(name)
        raise ProtocolError.new("unknown_tool", "no such tool: #{name}") unless tool

        args ||= {}

        case tool[:mode]
        when :primitive
          command =
            begin
              tool[:build].call(args)
            rescue ArgumentError => e
              # Primitives raises ArgumentError for bad enums / missing required.
              raise ProtocolError.new("argument_error", e.message)
            end
          observing(id, name, args) { @pool.run_command(id, command) }
        when :raw
          raw = args["command"].to_s
          raise ProtocolError.new("argument_error", "command is required") if raw.strip.empty?
          observing(id, name, args) { @pool.run_raw(id, raw) }
        when :poll
          @pool.poll(id)
        when :status
          @pool.connected?(id) ? "connected to #{@pool.describe(id)}" : "disconnected"
        when :map
          map_call(tool[:name], args, id)
        else
          raise ProtocolError.new("unknown_tool", "tool #{name} has unknown mode #{tool[:mode]}")
        end
      end

      # The map for a session, built lazily so a run that never navigates never
      # touches the map file.
      def cartographer(id = "default")
        @mu.synchronize do
          @cartographers[id] ||= Map::Cartographer.new(
            runner: ->(command) { @pool.run_command(id, command) },
            store:  Map::Store.new(Map::Store.path_for_endpoint(@pool.describe(id), dir: map_dir))
          )
        end
      end

      private

      def map_dir = @map_dir || Map::Store.default_dir

      # Run a gameplay command and fold its result into the map. The map is
      # strictly a bystander: it never changes what the tool returns, and a bug
      # in it must not cost the agent its move. Hence the rescue — a broken
      # parser degrades the map, not the game.
      def observing(id, name, args)
        text = yield
        begin
          cartographer(id).observe(name, args, text)
        rescue StandardError
          nil
        end
        text
      end

      def map_call(name, args, id)
        carto = cartographer(id)
        case name
        when "map_where"   then carto.where
        when "map_goto"
          dest = args["destination"].to_s
          raise ProtocolError.new("argument_error", "destination is required") if dest.strip.empty?
          carto.goto(dest)
        when "map_explore"
          carto.explore(count: args.fetch("count", 1) || 1,
                        mode: args.fetch("mode", "survey") || "survey")
        # No directions means "resume the route already on the stack".
        when "map_follow"
          dirs = args["directions"]
          carto.follow(dirs.to_s.strip.empty? ? nil : dirs)
        when "map_back"    then carto.back(steps: args["steps"])
        else
          raise ProtocolError.new("unknown_tool", "no such map tool: #{name}")
        end
      end
    end
  end
end
