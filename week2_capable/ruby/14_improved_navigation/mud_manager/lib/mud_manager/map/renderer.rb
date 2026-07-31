require_relative "world"

module MudManager
  module Map
    # Graph paper: a human-readable render of the map.
    #
    # Write-only, never read back (§6.1). A rendered map cannot disagree with
    # the map; a second file you both write and read will drift. It is also not
    # for the agent — this is for a person looking at what the thing learned.
    module Renderer
      module_function

      def markdown(world)
        out = []
        out << "# Graph paper"
        out << ""
        out << "#{world.room_count} rooms, #{world.edge_count} edges, " \
               "#{world.frontier_edges.size} unexplored exits."
        out << "Standing in: #{world.current&.title || '(unknown)'}"
        out << ""

        violations = world.violations + world.audit
        unless violations.empty?
          out << "## Contradictions"
          out << ""
          violations.each { |v| out << "- **#{v['kind']}** (seq #{v['seq']}): #{v['message']}" }
          out << ""
        end

        out << "## Rooms"
        out << ""
        world.rooms.values.sort_by { |r| [r.title, r.first_seq.to_i] }.each do |room|
          out << "### #{room.title} `#{room.id[0, 8]}`"
          out << ""
          out << "coords #{(room.coords || []).inspect} · exits #{room.exits.join(' ')}" \
                 "#{room.doors.empty? ? '' : " · doors #{room.doors.join(' ')}"}" \
                 "#{room.dark? ? ' · dark' : ''}"
          out << ""
          world.edges_from(room.id).sort_by(&:direction).each do |e|
            dest = e.to ? world.room(e.to)&.title : "**unexplored**"
            out << "- `#{e.direction}` -> #{dest}#{e.status == :open ? '' : " _(#{e.status})_"}"
          end
          out << ""
        end

        out.join("\n")
      end
    end
  end
end
