require "thor"
require "tty-prompt"
require "json"
require_relative "../services/auth_store"
require_relative "../generators/dockerfile"
require_relative "../generators/deploy_yml"
require_relative "../generators/secrets"
require_relative "../generators/env_example"
require_relative "../generators/gitignore"
require_relative "../generators/dockerignore"

module OctoberCMS
  module Commands
    class Init
      SUPPORTED_PHP_VERSIONS = %w[8.2 8.3 8.4 8.5].freeze
      DEFAULT_PHP_VERSION    = "8.3"

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

      def initialize(options = {})
        @options = options
        @prompt  = TTY::Prompt.new
      end

      def call
        detect_project!
        key = resolve_key
        ctx = gather_context(key)
        generate_files(ctx)
      end

      private

      def detect_project!
        missing = %w[composer.json artisan].reject { |f| File.exist?(File.join(Dir.pwd, f)) }
        return if missing.empty?
        raise Thor::Error, "No OctoberCMS project found in current directory " \
                           "(missing: #{missing.join(", ")}). " \
                           "Run this command from your OctoberCMS project root."
      end

      def resolve_key
        result = Services::AuthStore.resolve(project_dir: Dir.pwd)
        case result&.dig(:source)
        when :env
          puts "Using OCTOBER_LICENCE_KEY env var (will not be stored in project)."
          result[:key]
        when :project
          puts "Licence key already set for this project."
          result[:key]
        when :global
          if @prompt.yes?("Copy global licence key into this project's .kamal/secrets?", default: true)
            Services::AuthStore.store_project(result[:key], project_dir: Dir.pwd)
            puts "Licence key copied to .kamal/secrets."
          end
          result[:key]
        else
          puts "No licence key found. Running `auth setup` first..."
          run_auth_setup
          key = Services::AuthStore.resolve(project_dir: Dir.pwd)&.dig(:key)
          warn "Warning: no licence key configured. Fill in OCTOBER_LICENCE_KEY in .kamal/secrets before deploying." unless key
          key
        end
      end

      def run_auth_setup
        require_relative "auth"
        Commands::Auth.new([], {}).setup
      rescue SystemExit
        # auth setup exited non-zero; init continues with nil key
      end

      def gather_context(key)
        php_version = detect_php_version
        puts "PHP #{php_version} detected from composer.json."

        app_name = @prompt.ask("App name:", default: File.basename(Dir.pwd)).to_s.strip

        registry_choice = @prompt.select("Container registry:", REGISTRY_OPTIONS)
        registry_server = REGISTRY_SERVERS[registry_choice]
        registry_server = @prompt.ask("Registry server (e.g. registry.example.com):") if registry_server.nil?

        registry_username = @prompt.ask("Registry username:")
        raise Thor::Error, "Registry username is required." if registry_username.nil? || registry_username.strip.empty?

        image_default = [registry_server, registry_username, app_name].compact.join("/")
        image = @prompt.ask("Docker image:", default: image_default)

        servers = collect_servers

        domain = @prompt.ask("Domain (e.g. example.com):")
        raise Thor::Error, "Domain is required." if domain.nil? || domain.strip.empty?

        db_choice       = @prompt.select("Database:", ["Built-in MySQL accessory", "External (configure manually)"])
        mysql_accessory = db_choice.start_with?("Built-in")
        db_name         = @prompt.ask("Database name:", default: "october")
        db_username     = @prompt.ask("Database username:", default: "october")

        {
          service:             app_name,
          image:               image.strip,
          servers:             servers,
          domain:              domain.strip,
          registry_server:     registry_server,
          registry_username:   registry_username&.strip,
          mysql_accessory:     mysql_accessory,
          db_name:             db_name.strip,
          db_username:         db_username.strip,
          october_licence_key: key,
          php_version:         php_version,
        }
      end

      def detect_php_version
        data = JSON.parse(File.read(File.join(Dir.pwd, "composer.json")))
        constraint = data.dig("require", "php").to_s
        return DEFAULT_PHP_VERSION if constraint.empty?

        # Extract the first 8.x minor from the constraint string.
        # Handles: ">=8.4", "^8.3", "~8.3", "8.3.*", ">=8.2 <9.0", etc.
        match = constraint.match(/8\.(\d+)/)
        return DEFAULT_PHP_VERSION unless match

        min_minor = match[1].to_i
        SUPPORTED_PHP_VERSIONS.find { |v| v.split(".").last.to_i >= min_minor } || DEFAULT_PHP_VERSION
      rescue JSON::ParserError
        DEFAULT_PHP_VERSION
      end

      def collect_servers
        servers = []
        loop do
          label = servers.empty? ? "Server IP (blank to finish):" : "Another server IP (blank to finish):"
          ip = @prompt.ask(label)
          break if ip.nil? || ip.strip.empty?
          servers << ip.strip
        end
        raise Thor::Error, "At least one server IP is required." if servers.empty?
        servers
      end

      def generate_files(ctx)
        puts ""
        [
          [Generators::Dockerfile.new(ctx), "Dockerfile"],
          [Generators::DeployYml.new(ctx),  "config/deploy.yml"],
          [Generators::Secrets.new(ctx),    ".kamal/secrets"],
          [Generators::EnvExample.new(ctx), ".env.example"],
        ].each do |generator, label|
          path = File.join(Dir.pwd, label)
          if File.exist?(path)
            if @options[:skip_existing]
              puts "  skip    #{label}"
              next
            end
            unless @prompt.yes?("#{label} already exists. Overwrite?", default: false)
              puts "  skip    #{label}"
              next
            end
          end
          generator.write(project_dir: Dir.pwd)
          puts "  create  #{label}"
        end

        gi_changed = Generators::Gitignore.new.write(project_dir: Dir.pwd)
        puts gi_changed ? "  update  .gitignore" : "  skip    .gitignore"
        di_changed = Generators::Dockerignore.new.write(project_dir: Dir.pwd)
        puts di_changed ? "  update  .dockerignore" : "  skip    .dockerignore"
        puts "\nDone. Run `octobercms auth status` to verify your licence key, then `octobercms deploy`."
      end
    end
  end
end
