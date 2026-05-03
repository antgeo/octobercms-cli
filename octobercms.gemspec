require_relative "lib/octobercms/version"

Gem::Specification.new do |spec|
  spec.name          = "octobercms"
  spec.version       = OctoberCMS::VERSION
  spec.authors       = ["Anthony Georges"]
  spec.email         = ["anthony@anthonygeorges.com"]
  spec.summary       = "Deploy OctoberCMS with a single command"
  spec.homepage      = "https://github.com/antgeo/octobercms-cli"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "source_code_uri"   => "https://github.com/antgeo/octobercms-cli",
    "bug_tracker_uri"   => "https://github.com/antgeo/octobercms-cli/issues",
    "changelog_uri"     => "https://github.com/antgeo/octobercms-cli/releases",
    "rubygems_mfa_required" => "true",
  }

  spec.files         = Dir["lib/**/*", "bin/*", "README.md"]
  spec.bindir        = "bin"
  spec.executables   = ["octobercms"]

  spec.add_dependency "thor",        "~> 1.3"
  spec.add_dependency "tty-prompt",  "~> 0.23"
  spec.add_dependency "tty-command", "~> 0.10"
  spec.add_dependency "tty-logger",  "~> 0.6"
  spec.add_dependency "kamal",       "~> 2.0"
end
