require "thor"
require_relative "commands/auth"
require_relative "commands/init"

module OctoberCMS
  class CLI < Thor
    desc "auth SUBCOMMAND", "Manage the OctoberCMS licence key"
    subcommand "auth", Commands::Auth

    desc "init", "Scaffold deployment configuration for this OctoberCMS project"
    option :skip_existing, type: :boolean, default: false,
           desc: "Skip files that already exist without prompting"
    def init
      Commands::Init.new(skip_existing: options[:skip_existing]).call
    end

    def self.exit_on_failure? = true
  end
end
