require_relative "helper"

# The `prompt` event's only consumer is log_viz, which does:
#
#   next unless pending_user
#   message = event["messages"]&.last
#
# (log_viz/lib/log_viz/session.rb:78-85) — one message, once per turn. These
# expectations come from that parser, not from the logger's own output.
class TestLoggerPrompt < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "session.jsonl")
  end

  def teardown
    Boukensha.instance_variable_set(:@debug, false)
    FileUtils.remove_entry(@dir)
  end

  def history
    [
      Boukensha::Message.new(:user, "climb to level 15"),
      Boukensha::Message.new(:assistant, "ok"),
      Boukensha::Message.new(:tool_result, "You see a temple", "toolu_1"),
      Boukensha::Message.new(:user, "keep going")
    ]
  end

  def prompt_event(messages)
    logger = Boukensha::Logger.new(log: @log)
    logger.prompt(messages: messages, tools: { "look" => nil }, context_window: 200_000)
    logger.close
    File.readlines(@log).map { |l| JSON.parse(l) }.find { |e| e["phase"] == "prompt" }
  end

  def test_logs_only_the_newest_message
    event = prompt_event(history)

    assert_equal 1, event["messages"].size
    assert_equal "keep going", event["messages"].last["content"]
  end

  # log_viz reads messages.last, so the tail must still be the user's message.
  def test_the_logged_tail_is_what_log_viz_reads
    event = prompt_event(history)

    assert_equal "user", event["messages"].last["role"]
  end

  # Losing the history must not lose the size of it — this is the number that
  # shows how close the context is to the window.
  def test_message_count_still_reports_the_full_history_length
    event = prompt_event(history)

    assert_equal 4, event["message_count"]
    assert_equal 200_000, event["context_window"]
  end

  def test_debug_mode_restores_the_full_history
    Boukensha.debug!
    event = prompt_event(history)

    assert_equal 4, event["messages"].size
    assert_equal "climb to level 15", event["messages"].first["content"]
  end

  def test_an_empty_history_logs_no_messages
    event = prompt_event([])

    assert_empty event["messages"]
    assert_equal 0, event["message_count"]
  end
end
