require_relative "tool"
require_relative "message"

module Boukensha
  class Context
    attr_reader :system, :messages, :tools, :context_window, :working_dir,
                :turn_tokens, :compaction_threshold
    attr_accessor :current_tokens

    def initialize(system:, context_window: 200_000, working_dir: nil, compaction_threshold: 0.85)
      @system               = system
      @context_window       = context_window
      @working_dir          = working_dir ? File.expand_path(working_dir) : nil
      @compaction_threshold = compaction_threshold
      @messages             = []
      @tools                = {}
      @current_tokens       = 0
      @turn_tokens          = 0
    end

    def register_tool(tool)
      @tools[tool.name] = tool
    end

    def add_message(role, content, tool_use_id: nil)
      @messages << Message.new(role, content, tool_use_id)
    end

    # Update the known context size from the last API response's input_tokens.
    def update_tokens(n)
      @current_tokens = n.to_i
    end

    # Reset the cumulative per-turn spend counter. Called at the top of a turn.
    def reset_turn_tokens
      @turn_tokens = 0
    end

    # Add one API call's input+output tokens to the cumulative per-turn total.
    # This is the spend budget — distinct from current_tokens (window pressure).
    def add_turn_tokens(input, output)
      @turn_tokens += input.to_i + output.to_i
    end

    # Fraction of the context window currently in use (0.0–1.0).
    def usage_fraction
      @context_window > 0 ? @current_tokens.to_f / @context_window : 0.0
    end

    # Integer percentage (0–100).
    def usage_pct
      (usage_fraction * 100).round
    end

    # True when we should compact before the next API call. Defaults to the
    # configured compaction_threshold (a fraction of context_window).
    def needs_compaction?(threshold: compaction_threshold)
      usage_fraction >= threshold
    end

    # Drop roughly the oldest 40% of messages to free space, cutting only at a
    # boundary that leaves a valid history behind.
    #
    # The cut cannot land just anywhere. A MUD history is mostly
    # assistant[tool_use] / tool_result pairs, and slicing between them leaves a
    # tool_result whose tool_use is gone — which the API rejects with an opaque
    # 400. A cut that lands on an assistant message is rejected too, since the
    # first message must come from the user.
    #
    # Both constraints are satisfied by the same rule: advance the cut forward
    # until it lands on a real :user message. :tool_result is serialized as a
    # user-role message but is not one for this purpose, so it never qualifies.
    #
    # Returns the number of messages actually dropped — 0 when no safe boundary
    # exists ahead, which is honest rather than corrupting the history.
    def compact_messages!
      target = [(@messages.size * 0.40).ceil, @messages.size - 2].min
      cut    = safe_cut_point([target, 0].max)

      @messages = @messages.drop(cut)
      @current_tokens = 0 if cut.positive?
      cut
    end

    # Drop all conversation history, keeping tools and system prompt intact.
    def clear_messages!
      @messages = []
      @current_tokens = 0
    end

    def tool_count = @tools.size
    def turn_count = @messages.size

    def to_s
      "#<Context turns=#{turn_count} tools=#{tool_count} window=#{context_window} current=#{current_tokens}>"
    end

    private

    # First index at or after `target` holding a real :user message. Returns 0
    # when there is none — dropping nothing beats emitting an orphaned pair.
    def safe_cut_point(target)
      return 0 if target <= 0

      idx = target
      idx += 1 while idx < @messages.size && @messages[idx].role != :user
      idx < @messages.size ? idx : 0
    end
  end
end
