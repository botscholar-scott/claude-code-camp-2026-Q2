require_relative "helper"

# Compaction has one hard obligation: whatever it leaves behind must still be a
# sendable history. Two ways to violate that, and one rule fixes both —
#   * a kept tool_result whose tool_use was dropped   -> API 400, orphaned pair
#   * a history starting on an assistant message      -> API 400, first message
#                                                        must come from the user
# so the cut may only land on a real :user message.
#
# Expected shapes here come from the Anthropic Messages API contract, not from
# reading compact_messages! and writing down what it happens to do.
class TestContextCompaction < Minitest::Test
  def ctx_with(roles)
    ctx = Boukensha::Context.new(system: "s", context_window: 1000)
    roles.each_with_index do |role, i|
      if role == :tool_result
        ctx.add_message(:tool_result, "result #{i}", tool_use_id: "toolu_#{i}")
      else
        ctx.add_message(role, "msg #{i}")
      end
    end
    ctx
  end

  # One turn of MUD play: a goal, then assistant/tool_result pairs.
  def turn(pairs)
    [:user] + Array.new(pairs) { %i[assistant tool_result] }.flatten
  end

  # A REPL session is several such turns sharing one Context — which is the
  # only reason a :user message ever appears mid-history for the cut to find.
  def session(turns, pairs_per_turn)
    Array.new(turns) { turn(pairs_per_turn) }.flatten
  end

  def test_never_leaves_a_tool_result_as_the_first_message
    ctx = ctx_with(session(4, 3))

    assert_operator ctx.compact_messages!, :>, 0
    refute_equal :tool_result, ctx.messages.first&.role
  end

  def test_never_leaves_an_assistant_as_the_first_message
    ctx = ctx_with(session(4, 3))

    assert_operator ctx.compact_messages!, :>, 0
    assert_equal :user, ctx.messages.first.role
  end

  # The failing case as it actually occurs: a long run of pairs with no user
  # message anywhere near the 40% mark.
  def test_cut_advances_past_a_run_of_pairs_to_the_next_user_message
    ctx = ctx_with(session(4, 3))

    dropped = ctx.compact_messages!

    assert_operator dropped, :>, 0, "a user message exists ahead of the target"
    assert_equal :user, ctx.messages.first.role

    # Every surviving tool_result must have an assistant ahead of it in the
    # kept slice — that assistant is the one carrying its tool_use block.
    ctx.messages.each_with_index do |m, i|
      next unless m.role == :tool_result

      assert ctx.messages[0...i].any? { |p| p.role == :assistant },
             "tool_result at #{i} has no preceding assistant — orphaned pair"
    end
  end

  # No safe boundary ahead of the target: dropping nothing is correct.
  def test_drops_nothing_when_no_user_message_follows_the_target
    ctx = ctx_with(turn(10))
    before = ctx.messages.size

    dropped = ctx.compact_messages!

    assert_equal 0, dropped
    assert_equal before, ctx.messages.size
  end

  # current_tokens must not be zeroed when nothing was dropped, or the next
  # needs_compaction? check reads 0% usage on an untouched history.
  def test_current_tokens_survive_a_no_op_compaction
    ctx = ctx_with(turn(10))
    ctx.current_tokens = 900

    assert_equal 0, ctx.compact_messages!
    assert_equal 900, ctx.current_tokens
  end

  def test_current_tokens_reset_when_messages_were_dropped
    ctx = ctx_with(session(4, 3))
    ctx.current_tokens = 900

    assert_operator ctx.compact_messages!, :>, 0
    assert_equal 0, ctx.current_tokens
  end

  def test_compacting_an_empty_history_is_a_no_op
    ctx = ctx_with([])
    assert_equal 0, ctx.compact_messages!
    assert_empty ctx.messages
  end
end
