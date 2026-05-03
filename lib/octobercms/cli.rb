require "thor"
require_relative "commands/auth"
require_relative "commands/init"

module OctoberCMS
  class CLI < Thor
    desc "auth SUBCOMMAND", "Manage the OctoberCMS licence key"
    subcommand "auth", Commands::Auth

    desc "init", "Scaffold deployment configuration for this OctoberCMS project"
    subcommand "init", Commands::Init

    def self.exit_on_failure? = true
  end
end
