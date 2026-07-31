require_relative "helper"

# Boukensha::Tools::Mcp is the generic MCP host layer: point it at any MCP
# server and that server's tools become boukensha tools. These tests use the
# mud-manager daemon as "some MCP server" and deliberately never rely on it
# being a MUD.
class TestToolsMcp < Minitest::Test
  include McpTestHelper

  def setup
    @fake = start_fake_mud
  end

  def teardown
    @client&.close
    @fake&.stop
  end

  def register(registry, prefix: nil)
    @client = Boukensha::Tools::Mcp.register(
      registry, command: mud_manager_command, args: mud_manager_args,
                env: fake_mud_env(@fake), prefix: prefix
    )
  end

  # Registration with an explicit command: no MUD knowledge anywhere.
  def test_register_populates_the_registry_from_discovery
    ctx, registry = new_registry
    client = register(registry)

    assert_equal client.tools.size, ctx.tools.size
    assert ctx.tools.key?("look")
    assert_match(/You do: look/, registry.dispatch("look", {}).text)
  end

  # Prefixing is a policy applied agent-side. The server keeps its own names.
  def test_prefix_is_applied_locally_and_the_server_still_sees_bare_names
    ctx, registry = new_registry
    register(registry, prefix: "tbamud")

    assert ctx.tools.key?("tbamud__look")
    refute ctx.tools.key?("look")

    # If the prefix leaked onto the wire the daemon would reject this as an
    # unknown tool; getting the MUD's response back proves it didn't.
    assert_match(/You do: look/, registry.dispatch("tbamud__look", {}).text)
    assert_match(/You do: kill dragon/, registry.dispatch("tbamud__attack", "target" => "dragon").text)
  end

  # Proves prefixing is opt-in policy, not baked into the mechanism.
  def test_nil_prefix_yields_bare_names
    ctx, registry = new_registry
    register(registry, prefix: nil)
    assert ctx.tools.key?("look")
    refute ctx.tools.key?("tbamud__look")
  end

  # The server's schema is the schema. Nothing translates it, so `enum`,
  # `default` and `required` all survive as structure the API can enforce —
  # they used to be flattened into prose, dropped, and re-derived respectively.
  def test_the_servers_input_schema_is_carried_through_verbatim
    ctx, registry = new_registry
    client = register(registry)

    published = client.tools.find { |t| t["name"] == "move" }["inputSchema"]
    assert_equal published, ctx.tools["move"].parameters

    enum = ctx.tools["move"].parameters.dig("properties", "direction", "enum")
    assert_kind_of Array, enum, "enum must survive as structure, not prose"
    assert_includes enum, "north"
  end

  # The defect this replaced: every parameter was advertised as required, so a
  # tool documented as "call with NO arguments" was uncallable that way.
  def test_optional_parameters_are_not_advertised_as_required
    ctx, registry = new_registry
    register(registry)

    look = ctx.tools["look"]
    refute_empty look.properties, "look should still declare its optional properties"
    assert_empty look.required, "look requires nothing"

    backend = Boukensha::Backends::Anthropic.new(api_key: "test", model: "claude-haiku-4-5")
    emitted = backend.to_tools(ctx.tools).find { |t| t[:name] == "look" }
    assert_equal look.parameters, emitted[:input_schema]
    assert_empty(emitted[:input_schema]["required"] || [])
  end

  # A tool taking no arguments still needs a valid object schema.
  def test_a_tool_registered_without_parameters_gets_an_empty_object_schema
    ctx, registry = new_registry
    registry.tool("local", description: "no args") { "ok" }

    assert_equal({ "type" => "object", "properties" => {} }, ctx.tools["local"].parameters)
  end

  # Silent clobbering would be maddening to debug, so a collision is a hard
  # error naming the fix. Two servers sharing a prefix is the realistic case.
  def test_colliding_tool_names_raise
    _ctx, registry = new_registry
    register(registry, prefix: "tbamud")

    second = nil
    err = assert_raises(ArgumentError) do
      second = Boukensha::Tools::Mcp.register(
        registry, command: mud_manager_command, args: mud_manager_args,
                  env: fake_mud_env(@fake), prefix: "tbamud"
      )
    end
    assert_match(/collision on 'tbamud__look'/, err.message)
    assert_match(/prefix/, err.message)
  ensure
    second&.close
  end

  # A collision against a tool boukensha registered itself (not another MCP
  # server) must be caught too — a filesystem server advertising `read_file`
  # is the obvious one.
  def test_collision_with_an_existing_non_mcp_tool_raises
    _ctx, registry = new_registry
    registry.tool("look", description: "pre-existing") { "local" }

    err = assert_raises(ArgumentError) { register(registry) }
    assert_match(/collision on 'look'/, err.message)
  end
end
