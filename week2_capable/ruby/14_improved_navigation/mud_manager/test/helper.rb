require "minitest/autorun"
require "socket"
require "json"
require "stringio"
require "tmpdir"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "mud_manager"

# The map is a stored artifact and the daemon writes it as it plays, so a test
# run must not scribble into the real ~/.boukensha/maps.
ENV["MUD_MAP_DIR"] ||= Dir.mktmpdir("mud-map-test")
require "mud_manager/fake_mud"

# FakeMud lives in lib (reusable offline test double); alias it here so the
# existing tests keep referring to the bare constant.
FakeMud = MudManager::FakeMud

# Build a SessionPool wired to a FakeMud with valid credentials.
def pool_for(fake, name: "Gandalf", password: "secret")
  cfg = MudManager::Mcp::Config.new(host: "127.0.0.1", port: fake.port, name: name, password: password)
  MudManager::Mcp::SessionPool.new(default_config: cfg, timeout: 5.0)
end

# Drive a stdio server (McpServer / JsonLineServer) with an array of request
# hashes (or raw strings) and return the parsed response lines.
def drive(server_class, pool, requests)
  lines = requests.map { |r| r.is_a?(String) ? r : JSON.generate(r) }.join("\n") + "\n"
  input  = StringIO.new(lines)
  output = StringIO.new
  server_class.new(pool: pool, input: input, output: output).run
  output.string.each_line.map { |l| JSON.parse(l) }
end
