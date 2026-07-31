require_relative "helper"

# Characterization tests (Feathers) for what happens when an MCP tool call
# FAILS. Nothing here proposes a design; every assertion records what the code
# does today, so any change to it has to be deliberate.
#
# Tests marked DEFECT pin behaviour we believe is wrong. They are expected to
# be edited when the behaviour is fixed — that edit is the point.
#
# The rig is the real one: a real `mud-manager --mcp` subprocess, a real MCP
# wire, and a FakeMud it can talk to. No stubs below the boukensha boundary.
class TestMcpToolFailures < Minitest::Test
  include McpTestHelper

  def setup
    @fake = start_fake_mud
    @ctx, @registry = new_registry
    @client = Boukensha::Tools::Mcp.register(
      @registry, command: mud_manager_command, args: mud_manager_args,
                 env: fake_mud_env(@fake)
    )
  end

  def teardown
    @client&.close
    @fake&.stop
  end

  # ── The server's contract ────────────────────────────────────────────────
  # Independent source of truth: mud_manager/lib/mud_manager/mcp/server.rb:105
  # returns `isError: true` with the code embedded as "error [code]: message".
  # This is what the layers below are throwing away.

  def test_a_rejected_argument_is_reported_as_an_mcp_tool_error
    result = @client.call_tool("move", "direction" => "sideways")

    assert_equal true, result[:error]
    assert_match(/\Aerror \[argument_error\]:/, result[:text])
    assert_match(/expected one of north, east, south, west, up, down/, result[:text])
  end

  def test_an_unknown_tool_is_reported_as_an_mcp_tool_error
    result = @client.call_tool("nosuchtool", {})

    assert_equal true, result[:error]
    assert_match(/\Aerror \[unknown_tool\]:/, result[:text])
  end

  def test_a_successful_call_carries_no_error
    result = @client.call_tool("look", {})

    assert_equal false, result[:error]
    assert_match(/You do: look/, result[:text])
  end

  # ── The flag survives Registry#dispatch ─────────────────────────────────
  # It used to be folded into the string as an "error: " prefix, which both
  # destroyed the boolean and doubled up on mud-manager's own "error [code]: "
  # prefix. Everything downstream then saw an ordinary String.

  def test_dispatch_carries_the_error_flag
    failed  = @registry.dispatch("move", "direction" => "sideways")
    success = @registry.dispatch("look", {})

    assert_predicate failed, :error?
    refute_predicate success, :error?
  end

  def test_dispatch_does_not_rewrite_the_servers_text
    failed = @registry.dispatch("move", "direction" => "sideways")

    assert_equal "error [argument_error]: invalid direction: \"sideways\" " \
                 "(expected one of north, east, south, west, up, down)",
                 failed.text
  end

  # A tool registered by a run/repl block returns a bare String. It gets the
  # same type as an MCP tool, so the agent never type-tests what came back.
  def test_a_local_tool_returning_a_string_is_a_successful_result
    @registry.tool("local", description: "no args") { "done" }
    result = @registry.dispatch("local", {})

    assert_equal "done", result.text
    refute_predicate result, :error?
  end

  # ── A failed call is written to the transcript as a failure ─────────────
  # log_viz reads this flag directly (session.rb:133). Across the eleven
  # session files recorded before this fix there is not one `ok: false` in
  # 91+ tool calls, including calls that demonstrably failed.

  def test_a_failed_tool_call_is_logged_as_ok_false
    events = run_one_tool_turn("move", "direction" => "sideways")
    logged = events.find { |name, _| name == :tool_result }.last

    assert_equal false, logged[:ok]
    assert_match(/invalid direction/, logged[:error])
  end

  def test_a_successful_tool_call_is_logged_as_ok_true
    events = run_one_tool_turn("look", {})
    logged = events.find { |name, _| name == :tool_result }.last

    assert_equal true, logged[:ok]
    assert_nil logged[:error]
  end

  def test_the_model_still_receives_the_failure_text
    run_one_tool_turn("move", "direction" => "sideways")
    tool_result = @ctx.messages.find { |m| m.role == :tool_result }

    assert_match(/invalid direction/, tool_result.content)
    refute_match(/\Aerror: error \[/, tool_result.content,
                 "the doubled prefix is gone")
  end

  # ── F35: the transcript pairs results to calls by id, not by position ────

  def test_the_tool_use_id_reaches_both_log_events
    events = run_one_tool_turn("look", {})
    call   = events.find { |name, _| name == :tool_call }.last
    result = events.find { |name, _| name == :tool_result }.last

    assert_equal "tu_1", call[:tool_use_id]
    assert_equal "tu_1", result[:tool_use_id]
  end

  # ── F4: the model's mistakes come back; infrastructure does not ─────────
  # A tool that raises is either the model getting it wrong (recoverable, hand
  # it back) or the machinery underneath falling over (not recoverable, and
  # feeding it to the model buys two dozen more commands into nothing).

  def test_a_bad_argument_is_returned_to_the_model_as_a_failed_result
    @registry.tool("picky", description: "raises") { raise ArgumentError, "bad arg" }
    events = run_one_tool_turn("picky", {})
    logged = events.find { |name, _| name == :tool_result }.last

    assert_equal false, logged[:ok]
    assert_match(/bad arg/, logged[:error])
  end

  def test_an_unknown_tool_is_returned_to_the_model_as_a_failed_result
    events = run_one_tool_turn("no_such_tool", {})
    logged = events.find { |name, _| name == :tool_result }.last

    assert_equal false, logged[:ok]
    assert_match(/No tool registered/, logged[:error])
  end

  def test_an_infrastructure_failure_propagates_instead_of_reaching_the_model
    @registry.tool("broken", description: "dies") { raise IOError, "broken pipe" }

    err = assert_raises(IOError) { run_one_tool_turn("broken", {}) }
    assert_match(/broken pipe/, err.message)
  end

  # ── A dead MUD arrives two different ways, and only one is flagged ───────
  #
  # The fix list treats "the MUD is gone" as a single case (F4). It is not.
  # Which path you get depends on whether a telnet session had already been
  # established when the MUD went away, and the two disagree about whether
  # anything went wrong.

  # Path 1 — no session yet, so the pool tries to connect and is refused.
  # session_pool.rb:143 converts that to ProtocolError("connection_error").
  # This path works correctly: the failure is flagged.
  def test_an_unreachable_mud_is_reported_as_a_connection_error
    @fake.stop
    sleep 0.2

    result = @client.call_tool("look", {})

    assert_equal true, result[:error]
    assert_match(/\Aerror \[connection_error\]:/, result[:text])
  end

  # Path 2 is NOT tested here. If a session is already open and the peer goes
  # quiet, session.rb:163-166 rescues Timeout inside read_until_prompt and
  # returns the drained (empty) buffer, so nothing is ever flagged. Pinning it
  # costs 20s of wall clock against mud-manager's hardcoded 10.0s timeout, for
  # a low-likelihood failure that is not this epic's work. It is recorded in
  # the fix list instead.

  private

  # Drive one full agent turn that makes exactly one tool call, with the model
  # round-trip scripted. Returns the logger's event list.
  def run_one_tool_turn(tool, args = {})
    logger = RecordingLogger.new
    agent  = Boukensha::Agent.new(
      context: @ctx, registry: @registry, logger: logger,
      builder: PassThroughBuilder.new,
      client:  ScriptedClient.new([
        { "stop_reason" => "tool_use", "usage" => {},
          "content" => [{ "type" => "tool_use", "id" => "tu_1",
                          "name" => tool, "input" => args }] },
        { "stop_reason" => "end_turn", "usage" => {},
          "content" => [{ "type" => "text", "text" => "done" }] }
      ])
    )
    agent.run
    logger.events
  end

  # Records every logger call as [name, kwargs].
  class RecordingLogger
    attr_reader :events

    def initialize = @events = []
    def method_missing(name, **kwargs) = @events << [name, kwargs]
    def respond_to_missing?(*) = true
  end

  # Replays a scripted list of provider responses in place of a real API call.
  class ScriptedClient
    def initialize(responses) = @responses = responses
    def call(**) = @responses.shift
  end

  # The scripted responses are already in the normalized shape, so parsing is
  # the identity. Keeps the backend out of these tests entirely.
  class PassThroughBuilder
    def parse_response(response) = { stop_reason: response["stop_reason"],
                                     content: response["content"] }
    def backend = nil
  end
end
