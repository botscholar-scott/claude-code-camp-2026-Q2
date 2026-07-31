require_relative "../mcp/client"

module Boukensha
  module Tools
    # Mcp makes boukensha an MCP host: point it at any MCP server and every
    # tool that server advertises becomes a boukensha tool. It knows nothing
    # about any particular server — `command`/`args`/`env` is the standard
    # stdio transport config, the same triple every other MCP host uses.
    #
    #   Boukensha::Tools::Mcp.register(
    #     registry, command: "mud-manager", args: ["--mcp"],
    #     env: { "MUD_HOST" => "localhost" }, prefix: "tbamud"
    #   )
    #
    # `registry` is anything with the #tool surface — a Registry or the RunDSL
    # yielded to a run/repl block.
    #
    # prefix: scopes the discovered names ("tbamud" => tbamud__look). The
    # prefix is a property of the server entry, supplied by config; this module
    # applies whatever it is given. Names are only prefixed agent-side — the
    # server still sees its own bare name on the wire.
    module Mcp
      SEPARATOR = "__".freeze

      # Two tools claiming one name. Always fatal, even for an optional server:
      # this is a config contradiction, not a server being unreachable, and
      # silently dropping the loser is the expensive failure.
      class CollisionError < ArgumentError; end

      def self.register(registry, command:, args: [], env: {}, prefix: nil)
        client = Boukensha::Mcp::Client.spawn(command: command, args: args, env: env)
        # Close the server subprocess cleanly when the agent process exits.
        at_exit { client.close rescue nil }
        register_client(registry, client, prefix: prefix)
        client
      end

      # Register an already-spawned client's tools. Returns the count.
      def self.register_client(registry, client, prefix: nil)
        taken = begin
          registry.respond_to?(:tool_names) ? registry.tool_names.to_a : []
        end

        client.tools.each do |tool|
          remote = tool["name"]
          local  = prefixed(remote, prefix)

          if taken.include?(local)
            raise CollisionError,
                  "boukensha: MCP tool name collision on '#{local}' — a tool by that " \
                  "name is already registered. Give this server a distinct `prefix:` " \
                  "in mcp_servers."
          end
          taken << local

          registry.tool(local, description: tool["description"].to_s,
                               parameters: normalize_schema(tool["inputSchema"])) do |**kwargs|
            # Boukensha hands us symbol-keyed kwargs; the server wants strings.
            # Blank/omitted values are normalized server-side.
            #
            # The server's isError flag is carried, not folded into the text.
            # It used to be prefixed as "error: ", which both destroyed the
            # flag and doubled up on mud-manager's own "error [code]: " prefix.
            result = client.call_tool(remote, kwargs.transform_keys(&:to_s))
            ToolResult.new(result[:text], result[:error])
          end
        end
        client.tools.size
      end

      def self.prefixed(name, prefix)
        p = prefix.to_s.strip
        p.empty? ? name.to_s : "#{p}#{SEPARATOR}#{name}"
      end

      # An MCP server publishes a complete, correct JSON Schema for each tool.
      # Every provider's tool format embeds a JSON Schema too, so there is
      # nothing to convert — we carry the server's schema through untouched and
      # the backend drops it straight into its own envelope.
      #
      # This used to be a lossy translation into a private
      # `{ name => { type:, description: } }` shape, which discarded `required`
      # (the backend then re-derived it as "everything"), dropped `default`, and
      # flattened `enum` into prose in the description. Against mud-manager that
      # cost 16 of 42 parameters their optionality, 14 their enum, and 5 their
      # default — and made the 4 zero-argument tools uncallable as documented.
      #
      # The only normalization is supplying an empty object schema when a server
      # omits `inputSchema`, since providers require one.
      def self.normalize_schema(input_schema)
        return Boukensha::EMPTY_SCHEMA unless input_schema.is_a?(Hash) && !input_schema.empty?

        input_schema
      end
    end
  end
end
