require "thor"
require_relative "commands/auth"

module OctoberCMS
  class CLI < Thor
    desc "auth SUBCOMMAND", "Manage the OctoberCMS licence key"
    subcommand "auth", Commands::Auth

    def self.exit_on_failure? = true
  end
end
