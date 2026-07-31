require "json"
require "fileutils"
require "securerandom"
require "time"

module Boukensha
  class Logger
    DEFAULT_SESSION_DIR = "sessions".freeze

    attr_reader :session_id, :path

    def initialize(session_id: nil, dir: nil, log: nil, snapshot: {})
      @session_id = session_id || generate_session_id
      @path       = log || File.join(dir || default_dir, "#{@session_id}.jsonl")

      FileUtils.mkdir_p(File.dirname(@path))
      @log_io = File.open(@path, "a")
      write_log({ phase: "session_start" }.merge(snapshot))
    end

    def turn(n:)
      write_log(phase: "turn", n: n)
    end

    def iteration(n:, max:)
      write_log(phase: "iteration", n: n, max: max)
    end

    def limit_reached(kind:, n:, max:)
      write_log(phase: "limit_reached", kind: kind, n: n, max: max)
    end

    def turn_end(reason:, iterations:, tokens: nil)
      write_log(phase: "turn_end", reason: reason, iterations: iterations, tokens: tokens)
    end

    # Logs the newest message only, not the whole history.
    #
    # The history is re-sent to the model every iteration, so serializing all of
    # it here made this event O(n) per iteration and O(n^2) per turn — measured
    # at 46% of a session log, and roughly 780 KB for a single 25-iteration
    # turn. It was also redundant: assistant text is already a `response` event,
    # tool calls are `tool_call`, results are `tool_result`. The user's message
    # is the only thing unique to this event, and the only thing any consumer
    # reads (log_viz takes `messages.last` on the first prompt of a turn).
    #
    # `message_count` still reports the true history length, so nothing loses
    # sight of how big the context has grown. Set BOUKENSHA_DEBUG for the full
    # history when you need an exact replay.
    def prompt(messages:, tools:, context_window:)
      # NB: not Array(messages.last) — Message is a Struct, and Kernel#Array
      # calls #to_a on it, splatting it into its own members.
      tail   = messages.last ? [messages.last] : []
      logged = Boukensha.debug? ? messages : tail

      write_log(
        phase:          "prompt",
        message_count:  messages.size,
        messages:       logged.map { |m| serialize_message(m) },
        tool_count:     tools.size,
        tools:          tools.keys,
        context_window: context_window
      )
    end

    def compaction(before:, dropped:, context_window:)
      write_log(phase: "compaction", before: before, dropped: dropped, context_window: context_window)
    end

    # tool_use_id pairs a result back to its call. Without it a consumer has to
    # match by position, which only works because dispatch happens to be a
    # serial each — an implementation detail the transcript never stated.
    def tool_call(name:, args:, tool_use_id: nil)
      write_log(phase: "tool_call", name: name, args: args, tool_use_id: tool_use_id)
    end

    def tool_result(name:, result:, ok: true, error: nil, tool_use_id: nil)
      write_log(phase: "tool_result", name: name, result: result.to_s,
                ok: ok, error: error, tool_use_id: tool_use_id)
    end

    def response(text:, usage: nil, stop_reason: nil, task: nil, backend: nil)
      write_log(
        {
          phase: "response",
          text: text.to_s.strip,
          usage: usage,
          stop_reason: stop_reason
        }.merge(execution_metadata(task: task, backend: backend, usage: usage))
      )
    end

    def reasoning(text:, redacted: false)
      write_log(phase: "reasoning", text: text.to_s, redacted: redacted)
    end

    def plan(text:)
      write_log(phase: "plan", text: text.to_s.strip)
    end

    def raw(data:)
      return unless Boukensha.debug?

      write_log(phase: "raw", data: data)
    end

    def subscribe(&block)
      @subscribers ||= []
      @subscribers << block
    end

    def close
      @log_io&.close
    end

    private

    def default_dir
      File.join(Boukensha.config.dir, DEFAULT_SESSION_DIR)
    end

    def write_log(event)
      @log_io.puts JSON.generate(event.merge(session_id: @session_id, at: Time.now.iso8601))
      @log_io.flush
      @subscribers&.each { |s| s.call(event) }
    end

    def generate_session_id
      "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(4)}"
    end

    def serialize_message(msg)
      { role: msg.role, content: msg.content }
    end

    def execution_metadata(task:, backend:, usage:)
      return {} unless task || backend || usage

      tokens = usage_tokens(usage)
      metadata = {
        task: task_name(task),
        provider: provider_name(backend),
        model: backend&.model,
        usage_unit: backend&.respond_to?(:usage_unit) ? backend.usage_unit : nil,
        usage_level: backend&.respond_to?(:usage_level) ? backend.usage_level : nil,
        input_tokens: tokens[:input],
        output_tokens: tokens[:output],
        cost_usd: estimate_cost(backend, tokens)
      }
      metadata.compact
    end

    def task_name(task)
      task&.respond_to?(:task_name) ? task.task_name : task&.to_s
    end

    def provider_name(backend)
      return nil unless backend

      backend.class.name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def usage_tokens(usage)
      usage ||= {}
      {
        input: first_integer(usage, "input_tokens", "prompt_tokens", "promptTokenCount", "prompt_eval_count"),
        output: first_integer(usage, "output_tokens", "completion_tokens", "candidatesTokenCount", "eval_count")
      }
    end

    def first_integer(hash, *keys)
      keys.each do |key|
        value = hash[key] || hash[key.to_sym]
        return Integer(value) unless value.nil?
      end
      nil
    rescue ArgumentError, TypeError
      nil
    end

    def estimate_cost(backend, tokens)
      return nil unless backend&.respond_to?(:estimate_cost)
      return nil unless tokens[:input] && tokens[:output]

      backend.estimate_cost(input_tokens: tokens[:input], output_tokens: tokens[:output])
    end
  end
end
