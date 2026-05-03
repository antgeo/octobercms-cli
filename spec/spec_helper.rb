require "open3"
require "net/http"
require "socket"
require "json"
require "securerandom"
require "shellwords"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.include DockerHelpers

  config.filter_run_when_matching :focus

  config.before(:suite) do
    if DockerHelpers.image_missing?(DockerHelpers::INFRA_IMAGE)
      RSpec.configuration.filter_run_excluding integration: true
      RSpec.configuration.reporter.message(
        "WARNING: infrastructure image '#{DockerHelpers::INFRA_IMAGE}' not found — " \
        "all tests skipped.\n" \
        "Build it first (no credentials needed):\n" \
        "  docker build --target base -f docker/Dockerfile -t #{DockerHelpers::INFRA_IMAGE} ."
      )
    elsif DockerHelpers.full_image_missing?
      RSpec.configuration.filter_run_excluding full: true
      RSpec.configuration.reporter.message(
        "INFO: production image '#{DockerHelpers::IMAGE}' not found — " \
        ":full tests skipped.\n" \
        "Build it to run health check state tests:\n" \
        "  DOCKER_BUILDKIT=1 docker build \\\n" \
        "    --secret id=composer_auth,src=~/.composer/auth.json \\\n" \
        "    -f docker/Dockerfile -t #{DockerHelpers::IMAGE} ."
      )
    end
  end
end
