require "thor"
require "tty-prompt"
require_relative "../services/auth_store"
require_relative "../generators/dockerfile"
require_relative "../generators/deploy_yml"
require_relative "../generators/secrets"
require_relative "../generators/env_example"
require_relative "../generators/gitignore"

module OctoberCMS
  module Commands
    class Init < Thor
      REGISTRY_OPTIONS = [
        "GitHub Container Registry (ghcr.io)",
        "Docker Hub (docker.io)",
        "Other",
      ].freeze

      REGISTRY_SERVERS = {
        "GitHub Container Registry (ghcr.io)" => "ghcr.io",
        "Docker Hub (docker.io)"              => "docker.io",
        "Other"                               => nil,
      }.freeze

      default_task :init

      desc "init", "Scaffold deployment configuration for this OctoberCMS project"
      option :skip_existing, type: :boolean, default: false,
             desc: "Skip files that already exist without prompting"
      def init
        detect_project!
        prompt = TTY::Prompt.new
        key    = resolve_key(prompt)
        ctx    = gather_context(prompt, key)
        generate_files(ctx, prompt)
      end

      no_commands do
        def detect_project!
          missing = %w[composer.json artisan].reject { |f| File.exist?(File.join(Dir.pwd, f)) }
          return if missing.empty?
          raise Thor::Error, "No OctoberCMS project found in current directory " \
                             "(missing: #{missing.join(", ")}). " \
                             "Run this command from your OctoberCMS project root."
        end

        def resolve_key(prompt)
          result = Services::AuthStore.resolve(project_dir: Dir.pwd)
          case result&.dig(:source)
          when :env
            puts "Using OCTOBER_LICENCE_KEY env var (will not be stored in project)."
            result[:key]
          when :project
            puts "Licence key already set for this project."
            result[:key]
          when :global
            if prompt.yes?("Copy global licence key into this project's .kamal/secrets?", default: true)
              Services::AuthStore.store_project(result[:key], project_dir: Dir.pwd)
              puts "Licence key copied to .kamal/secrets."
            end
            result[:key]
          else
            puts "No licence key found. Running `auth setup` first..."
            run_auth_setup
            Services::AuthStore.resolve(project_dir: Dir.pwd)&.dig(:key)
          end
        end

        def run_auth_setup
          require_relative "auth"
          Commands::Auth.new([], {}).setup
        end

        def gather_context(prompt, key)
          app_name = prompt.ask("App name:", default: File.basename(Dir.pwd))

          registry_choice = prompt.select("Container registry:", REGISTRY_OPTIONS)
          registry_server = REGISTRY_SERVERS[registry_choice]
          registry_server = prompt.ask("Registry server (e.g. registry.example.com):") if registry_server.nil?

          registry_username = prompt.ask("Registry username:")

          image_default = [registry_server, registry_username, app_name].compact.join("/")
          image = prompt.ask("Docker image:", default: image_default)

          servers = collect_servers(prompt)

          domain = prompt.ask("Domain (e.g. example.com):")
          raise Thor::Error, "Domain is required." if domain.nil? || domain.strip.empty?

          db_choice       = prompt.select("Database:", ["Built-in MySQL accessory", "External (configure manually)"])
          mysql_accessory = db_choice.start_with?("Built-in")
          db_name         = prompt.ask("Database name:", default: "october")
          db_username     = prompt.ask("Database username:", default: "october")

          {
            service:             app_name.strip,
            image:               image.strip,
            servers:             servers,
            domain:              domain.strip,
            registry_server:     registry_server,
            registry_username:   registry_username&.strip,
            mysql_accessory:     mysql_accessory,
            db_name:             db_name.strip,
            db_username:         db_username.strip,
            october_licence_key: key,
          }
        end

        def collect_servers(prompt)
          servers = []
          loop do
            label = servers.empty? ? "Server IP (blank to finish):" : "Another server IP (blank to finish):"
            ip = prompt.ask(label)
            break if ip.nil? || ip.strip.empty?
            servers << ip.strip
          end
          raise Thor::Error, "At least one server IP is required." if servers.empty?
          servers
        end

        def generate_files(ctx, prompt)
          puts ""
          [
            [Generators::Dockerfile.new(ctx), "Dockerfile"],
            [Generators::DeployYml.new(ctx),  "config/deploy.yml"],
            [Generators::Secrets.new(ctx),    ".kamal/secrets"],
            [Generators::EnvExample.new(ctx), ".env.example"],
          ].each do |generator, label|
            path = File.join(Dir.pwd, label)
            if File.exist?(path)
              if options[:skip_existing]
                puts "  skip    #{label}"
                next
              end
              unless prompt.yes?("#{label} already exists. Overwrite?", default: false)
                puts "  skip    #{label}"
                next
              end
            end
            generator.write(project_dir: Dir.pwd)
            puts "  create  #{label}"
          end

          Generators::Gitignore.new.write(project_dir: Dir.pwd)
          puts "  update  .gitignore"
          puts "\nDone. Run `octobercms auth status` to verify your licence key, then `octobercms deploy`."
        end
      end
    end
  end
end
