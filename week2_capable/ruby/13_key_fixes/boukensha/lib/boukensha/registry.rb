require_relative "errors"

module Boukensha
  class Registry
    def initialize(context)
      @context = context
    end

    # parameters: a JSON Schema object (see Boukensha::Tool). Defaults to the
    # empty object schema, which is what a tool taking no arguments needs.
    def tool(name, description:, parameters: EMPTY_SCHEMA, &block)
      tool = Tool.new(name.to_s, description, parameters, block)
      @context.register_tool(tool)
      tool
    end

    def tool_names
      @context.tools.keys
    end

    # Always returns a ToolResult, whatever the tool block returned, so the
    # agent never has to ask what kind of thing it got back.
    def dispatch(name, args = {})
      tool = @context.tools[name.to_s]
      raise UnknownToolError, "No tool registered as '#{name}'" unless tool
      as_result(tool.block.call(**args.transform_keys(&:to_sym)))
    end

    private

    # An MCP tool hands back a ToolResult carrying the server's isError flag.
    # A tool registered by a run/repl block hands back a bare String, which by
    # definition succeeded: it returned instead of raising.
    def as_result(value)
      value.is_a?(ToolResult) ? value : ToolResult.new(value.to_s, false)
    end
  end
end