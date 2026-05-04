require "thor"
require_relative "commands/auth"
require_relative "commands/init"
require_relative "commands/deploy"
require_relative "commands/doctor"

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

    desc "deploy", "Build, migrate, and deploy to production"
    option :skip_migrate, type: :boolean, default: false,
           desc: "Skip database migrations"
    def deploy
      Commands::Deploy.new(skip_migrate: options[:skip_migrate]).call
    end

    desc "build", "Build and push the Docker image"
    def build
      Commands::Deploy.new.build_only
    end

    desc "migrate", "Run pending database migrations in the running container"
    def migrate
      Commands::Deploy.new.migrate_only
    end

    desc "doctor", "Check pre-deploy requirements"
    option :validate, type: :boolean, default: false,
           desc: "Validate licence key against gateway.octobercms.com"
    def doctor
      success = Commands::Doctor.new(validate: options[:validate]).call
      exit 1 unless success
    end

    desc "console", "Open an interactive shell in the running container"
    def console
      Commands::Deploy.new.console
    end

    desc "logs", "Tail the application logs"
    option :lines, type: :numeric, default: 100,
           desc: "Number of lines to tail"
    option :no_follow, type: :boolean, default: false,
           desc: "Print without following"
    def logs
      Commands::Deploy.new(
        lines:     options[:lines],
        no_follow: options[:no_follow]
      ).logs
    end

    def self.exit_on_failure? = true
  end
end
