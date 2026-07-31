require_relative "helper"

# F25 — a reply cut off at the output ceiling is not a completed turn.
#
# Expected values come from each provider's published response shape, not from
# boukensha: Anthropic's six stop_reason values, Gemini's finishReason, Ollama's
# done_reason, and the Responses API's incomplete_details.reason.
class TestStopReason < Minitest::Test
  def anthropic = Boukensha::Backends::Anthropic.new(api_key: "test", model: "claude-haiku-4-5")

  # ── Normalization keeps the provider's word alongside ours ──────────────

  def test_a_completed_reply_is_end_turn
    parsed = anthropic.parse_response("stop_reason" => "end_turn", "content" => [])

    assert_equal "end_turn", parsed[:stop_reason]
    assert_equal "end_turn", parsed[:raw_stop_reason]
  end

  def test_a_truncated_reply_is_not_reported_as_a_completed_one
    parsed = anthropic.parse_response("stop_reason" => "max_tokens", "content" => [])

    assert_equal "max_tokens", parsed[:stop_reason]
    assert_equal "max_tokens", parsed[:raw_stop_reason]
  end

  # The other four of Anthropic's six used to collapse into "end_turn" with no
  # trace. They still end the turn, but the transcript can now say which.
  def test_the_remaining_stop_reasons_end_the_turn_but_keep_their_name
    %w[stop_sequence pause_turn refusal].each do |raw|
      parsed = anthropic.parse_response("stop_reason" => raw, "content" => [])

      assert_equal "end_turn", parsed[:stop_reason], raw
      assert_equal raw, parsed[:raw_stop_reason]
    end
  end

  def test_tool_use_still_routes_to_tool_use
    parsed = anthropic.parse_response("stop_reason" => "tool_use", "content" => [])

    assert_equal "tool_use", parsed[:stop_reason]
  end

  # ── Each provider spells truncation differently ─────────────────────────

  def test_gemini_reports_truncation_as_MAX_TOKENS
    backend = Boukensha::Backends::Gemini.new(api_key: "test", model: gemini_model)
    parsed  = backend.parse_response(
      "candidates" => [{ "finishReason" => "MAX_TOKENS",
                         "content" => { "parts" => [{ "text" => "cut off" }] } }]
    )

    assert_equal "max_tokens", parsed[:stop_reason]
    assert_equal "MAX_TOKENS", parsed[:raw_stop_reason]
  end

  def test_ollama_reports_truncation_as_length
    backend = Boukensha::Backends::Ollama.new(model: ollama_model)
    parsed  = backend.parse_response(
      "done_reason" => "length", "message" => { "content" => "cut off" }
    )

    assert_equal "max_tokens", parsed[:stop_reason]
    assert_equal "length", parsed[:raw_stop_reason]
  end

  def test_openai_reports_truncation_in_incomplete_details
    backend = Boukensha::Backends::OpenAI.new(api_key: "test", model: openai_model)
    parsed  = backend.parse_response(
      "status" => "incomplete",
      "incomplete_details" => { "reason" => "max_output_tokens" },
      "output" => []
    )

    assert_equal "max_tokens", parsed[:stop_reason]
    assert_equal "max_output_tokens", parsed[:raw_stop_reason]
  end

  # ── The agent records it as its own outcome ─────────────────────────────

  def test_the_turn_ends_as_max_output_tokens_not_completed
    events = run_turn_ending_with("max_tokens")
    reason = events.find { |name, _| name == :turn_end }.last[:reason]

    assert_equal "max_output_tokens", reason
  end

  def test_a_real_completion_still_ends_as_completed
    events = run_turn_ending_with("end_turn")
    reason = events.find { |name, _| name == :turn_end }.last[:reason]

    assert_equal "completed", reason
  end

  # The viewer renders stop_reason off the response event, so it must carry the
  # provider's word rather than the normalization.
  def test_the_response_event_carries_the_providers_own_stop_reason
    events = run_turn_ending_with("refusal")
    logged = events.find { |name, _| name == :response }.last

    assert_equal "refusal", logged[:stop_reason]
  end

  private

  # Pick whatever model each backend actually declares, so this file doesn't
  # break when the model tables move (F6 will move them).
  def gemini_model = Boukensha::Backends::Gemini.models.keys.first
  def ollama_model = Boukensha::Backends::Ollama.models.keys.first
  def openai_model = Boukensha::Backends::OpenAI.models.keys.first

  def run_turn_ending_with(raw_stop_reason)
    ctx    = Boukensha::Context.new(system: "test")
    logger = RecordingLogger.new
    agent  = Boukensha::Agent.new(
      context: ctx, registry: Boukensha::Registry.new(ctx), logger: logger,
      builder: AnthropicShapedBuilder.new,
      client:  ScriptedClient.new([
        { "stop_reason" => raw_stop_reason, "usage" => {},
          "content" => [{ "type" => "text", "text" => "partial answer" }] }
      ])
    )
    agent.run
    logger.events
  end

  # Parses through the real Anthropic backend, so the normalization under test
  # is the shipping one rather than a restatement of it.
  class AnthropicShapedBuilder
    def initialize
      @backend = Boukensha::Backends::Anthropic.new(api_key: "test", model: "claude-haiku-4-5")
    end

    def parse_response(response) = @backend.parse_response(response)
    def backend = nil
  end

  class RecordingLogger
    attr_reader :events

    def initialize = @events = []
    def method_missing(name, **kwargs) = @events << [name, kwargs]
    def respond_to_missing?(*) = true
  end

  class ScriptedClient
    def initialize(responses) = @responses = responses
    def call(**) = @responses.shift
  end
end
