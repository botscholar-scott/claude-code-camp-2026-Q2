require "json"
require "fileutils"
require_relative "world"

module MudManager
  module Map
    # The map is a stored artifact (§6.1): written as you play, loaded at boot.
    # Play for fifty hours, map the city, come back tomorrow, and boukensha
    # already knows the way to the bakery.
    #
    # It is keyed on host:port, not on character, because the map is a property
    # of the world rather than of whoever is walking around in it.
    class Store
      def self.default_dir
        ENV["MUD_MAP_DIR"] ||
          File.join(File.expand_path(ENV.fetch("BOUKENSHA_DIR", File.join(Dir.home, ".boukensha"))), "maps")
      end

      def self.path_for(host, port, dir: default_dir)
        path_for_endpoint("#{host}:#{port}", dir: dir)
      end

      # `endpoint` is whatever SessionPool#describe returns ("localhost:4000").
      def self.path_for_endpoint(endpoint, dir: default_dir)
        File.join(dir, "#{endpoint.to_s.gsub(/[^A-Za-z0-9._-]+/, '_')}.json")
      end

      attr_reader :path

      def initialize(path)
        @path = path
      end

      def load
        return World.new unless @path && File.exist?(@path)
        World.from_h(JSON.parse(File.read(@path)))
      rescue JSON::ParserError, SystemCallError
        # A corrupt map should cost you today's exploration, not the session.
        World.new
      end

      # Atomic: a crash mid-write must not leave a half-map behind, since the
      # next boot trusts `position` to route immediately.
      def save(world)
        return unless @path
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.#{Process.pid}.tmp"
        File.write(tmp, JSON.generate(world.to_h))
        File.rename(tmp, @path)
        world.clean!
        @path
      rescue SystemCallError
        nil
      end
    end
  end
end
