module Boukensha
  # `parameters` is a JSON Schema object describing the tool's arguments — the
  # same shape MCP publishes as `inputSchema` and every provider embeds in its
  # own tool format. It is carried through verbatim: nothing re-derives
  # `required` or rewrites `enum` / `default`.
  Tool = Struct.new(:name, :description, :parameters, :block) do
    def properties
      parameters.is_a?(Hash) ? (parameters["properties"] || {}) : {}
    end

    def required
      parameters.is_a?(Hash) ? (parameters["required"] || []) : []
    end

    def to_s
      "#<Tool name=#{name} description=#{description.to_s[0..40]} params=#{properties.keys}>"
    end
  end

  # Providers require an object schema, so a tool that takes no arguments gets
  # an empty one rather than `{}`.
  EMPTY_SCHEMA = { "type" => "object", "properties" => {} }.freeze
end
