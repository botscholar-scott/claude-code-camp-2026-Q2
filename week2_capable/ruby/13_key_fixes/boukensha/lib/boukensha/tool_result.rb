module Boukensha
  # What a tool call produced: the text the model sees, plus whether the tool
  # reported failure.
  #
  # `error` is not an exception. MCP returns a tool-level failure as a
  # *successful* JSON-RPC response carrying `isError: true` (bad arguments,
  # unknown tool, a dead connection), and the model is expected to read it and
  # act on it. Collapsing that flag into the text — which is what this type
  # replaced — left every consumer unable to tell a failed call from a working
  # one, so the session transcript recorded 91 tool calls in a row as `ok:
  # true` with no way to know better.
  #
  # Registry#dispatch returns one of these for *every* tool, MCP or not, so no
  # caller has to type-test what came back.
  ToolResult = Struct.new(:text, :error) do
    def error? = !!error

    # Tool results go onto the wire as text, so a plain #to_s keeps every
    # existing caller working.
    def to_s = text.to_s
  end
end
