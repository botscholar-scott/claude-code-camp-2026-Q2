require_relative "helper"

# The MUD talks when nobody asked it to. Hunger, thirst, the sun rising, another
# player arriving: all of it lands in the buffer between commands, and every one
# of those blocks is followed by a prompt, exactly like a real reply.
#
# So "read until something is there" and "read until a prompt" both have a way
# of answering the question nobody asked. Live, that produced an entire session
# of the agent reporting "tried it, didn't work" while the MUD's actual answer
# sat in the buffer waiting to be attributed to the NEXT command:
#
#   open gate  ->  "You are hungry. You are thirsty."     (a tick, not the reply)
#   poll       ->  "It seems to be locked."               (the reply, one late)
#
# The gate was locked the whole time and nothing said so.
class TestSessionPoolReads < Minitest::Test
  def setup
    @fake = FakeMud.new
    @pool = pool_for(@fake)
    @pool.connect("default")
  end

  def teardown
    @pool&.close_all
    @fake&.stop
  end

  # read_until_quiet's "quiet" test is satisfied by data that arrived ages ago,
  # so with async text already buffered it used to return that text instantly
  # and never wait for the reply at all.
  def test_a_raw_command_is_answered_by_its_own_reply_not_by_a_stale_tick
    @fake.push("\r\nYou are hungry.\r\nYou are thirsty.\r\n\r\n25H 100M 84V > ")
    sleep 0.2   # let it land in the buffer, exactly as a tick would

    out = @pool.run_raw("default", "open gate")

    assert_includes out, "open gate", "the reply to the command we sent"
    refute_includes out, "You are hungry", "not the tick that happened to be sitting there"
  end

  def test_a_structured_command_is_likewise_answered_by_its_own_reply
    @fake.push("\r\nThe sun rises.\r\n\r\n25H 100M 84V > ")
    sleep 0.2

    out = @pool.run_command("default", MudManager::Primitives.move("north"))

    assert_includes out, "north"
    refute_includes out, "The sun rises"
  end

  # The stale text is not silently destroyed either — draining it is what makes
  # the next read honest, and poll is where unsolicited output belongs.
  def test_async_output_still_reaches_poll_when_nothing_else_is_running
    @fake.push("\r\nA goblin arrives.\r\n\r\n25H 100M 84V > ")
    sleep 0.2

    assert_includes @pool.poll("default"), "A goblin arrives"
  end
end
