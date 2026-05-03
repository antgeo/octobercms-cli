require "rspec/core/rake_task"

# Infrastructure image (no OctoberCMS, no credentials needed):
#   docker build --target base -f docker/Dockerfile -t octobercms:base .
#
# Production image (OctoberCMS installed, requires gateway credentials):
#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=composer_auth,src=~/.composer/auth.json \
#     -f docker/Dockerfile -t octobercms:latest .

# All tests (skips :full if production image is absent).
RSpec::Core::RakeTask.new(:spec)

# Fast: generate-env.sh behavior + image structure. Only needs octobercms:base.
# ~30s after the infra image is built.
RSpec::Core::RakeTask.new("spec:fast") do |t|
  t.rspec_opts = "--tag integration --tag ~full"
end

# Full: all tests including MySQL health check state tests.
# Needs both octobercms:base and octobercms:latest.
RSpec::Core::RakeTask.new("spec:full") do |t|
  t.rspec_opts = "--tag integration"
end

task default: :spec
