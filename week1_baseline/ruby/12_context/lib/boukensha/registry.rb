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

    def dispatch(name, args = {})
      tool = @context.tools[name.to_s]
      raise UnknownToolError, "No tool registered as '#{name}'" unless tool
      tool.block.call(**args.transform_keys(&:to_sym))
    end
  end
end