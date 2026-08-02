require_relative "helper"
require "rubygems/package"

# The default system prompt ships inside the package and is found relative to
# it. Nothing here should ever depend on an environment variable: BOUKENSHA_PATH
# is not exported by the loader and is absent entirely for the bundled gem, and
# BOUKENSHA_DIR is the user's config directory, which owns the *override*
# rather than the default.
#
# These exist because the path rotted silently once already. Config::PROMPTS_DIR
# was a "../" count copied forward from a shallower layout, so it resolved to a
# directory that does not exist — and nothing complained, because a missing
# default prompt returns nil instead of raising and a `prompt_override` in
# settings.yaml bypasses it altogether.
class TestPackagedPrompts < Minitest::Test
  def test_the_packaged_prompts_directory_exists
    assert Dir.exist?(Boukensha::Config::PROMPTS_DIR),
           "Config::PROMPTS_DIR does not exist: #{Boukensha::Config::PROMPTS_DIR}"
  end

  def test_the_package_root_is_two_levels_above_this_file
    assert File.exist?(File.join(Boukensha::Config::PACKAGE_ROOT, "boukensha.gemspec")),
           "PACKAGE_ROOT should be the package root, got #{Boukensha::Config::PACKAGE_ROOT}"
  end

  # The failure mode that hid the bug: no exception, just a nil system prompt.
  def test_the_default_system_prompt_loads_with_no_override
    text = Boukensha::Tasks::Player.system_prompt(
      {}, user_prompts_dir: nil, default_prompts_dir: Boukensha::Config::PROMPTS_DIR
    )

    refute_nil text, "the shipped default system prompt did not load"
    refute_empty text.strip
  end

  def test_it_does_not_depend_on_any_environment_variable
    %w[BOUKENSHA_PATH BOUKENSHA_DIR].each do |var|
      old = ENV.delete(var)
      begin
        assert Dir.exist?(Boukensha::Config::PROMPTS_DIR),
               "PROMPTS_DIR broke with #{var} unset"
      ensure
        ENV[var] = old if old
      end
    end
  end

  # A gem install has no step folder to fall back on, so an unpackaged prompt
  # directory means no default prompt at all for anyone who installs it.
  def test_the_gemspec_packages_the_prompts
    spec = Gem::Specification.load(
      File.join(Boukensha::Config::PACKAGE_ROOT, "boukensha.gemspec")
    )

    refute_empty spec.files.grep(%r{\Aprompts/.*\.md\z}),
                 "boukensha.gemspec does not package prompts/, so an installed gem has no default prompt"
  end
end
