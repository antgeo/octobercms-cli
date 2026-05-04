require "net/http"
require "uri"
require "tty-command"
require_relative "../services/auth_store"
require_relative "../services/kamal"

module OctoberCMS
  module Commands
    class Doctor
      REQUIRED_SECRETS = %w[
        KAMAL_REGISTRY_PASSWORD
        OCTOBER_LICENCE_KEY
        APP_KEY
        DB_DATABASE
        DB_USERNAME
        DB_PASSWORD
      ].freeze

      GITIGNORE_REQUIRED = %w[auth.json .env .kamal/secrets].freeze

      GATEWAY_URL = "https://gateway.octobercms.com/packages.json"

      def initialize(options = {})
        @validate    = options[:validate]
        @fast        = options[:fast]
        @quiet       = options[:quiet]
        @project_dir = options.fetch(:project_dir, Dir.pwd)
        @kamal       = options[:kamal]
        @cmd         = options[:cmd]
        @failures    = []
      end

      def call
        puts "Running pre-deploy checks..." unless @quiet
        puts "" unless @quiet

        check_deploy_yml
        check_secrets_file
        check_licence_key
        check_gitignore

        unless @fast
          check_docker_running
          check_kamal_config
          check_git_history
          check_licence_validity if @validate
        end

        if @failures.empty?
          puts "\nAll checks passed." unless @quiet
          true
        else
          puts "\n#{@failures.size} check(s) failed." unless @quiet
          false
        end
      end

      private

      def pass(msg)
        puts "  ✓  #{msg}" unless @quiet
      end

      def fail!(msg)
        puts "  ✗  #{msg}" unless @quiet
        @failures << msg
      end

      # M3: single AuthStore call, memoised for all checks that need key or source.
      def resolved_result
        @resolved_result ||= Services::AuthStore.resolve(project_dir: @project_dir)
      end

      def resolved_key
        resolved_result&.dig(:key)
      end

      def check_deploy_yml
        if File.exist?(File.join(@project_dir, "config", "deploy.yml"))
          pass("config/deploy.yml exists")
        else
          fail!("config/deploy.yml not found — run `octobercms init` first")
        end
      end

      def check_secrets_file
        secrets_path = File.join(@project_dir, ".kamal", "secrets")
        unless File.exist?(secrets_path)
          fail!(".kamal/secrets not found — run `octobercms init` first")
          return
        end
        content = File.read(secrets_path)
        # M5: reject KEY="" (empty quoted) and KEY= (no value) as unusable.
        missing = REQUIRED_SECRETS.reject do |k|
          content.match?(/^#{Regexp.escape(k)}=(?:"[^"]+"|[^\s"]+)/)
        end
        if missing.empty?
          pass(".kamal/secrets has all required keys set")
        else
          fail!(".kamal/secrets is missing values for: #{missing.join(", ")}")
        end
      end

      def check_licence_key
        if resolved_result
          pass("Licence key configured (source: #{resolved_result[:source]})")
        else
          fail!("No licence key configured — run `octobercms auth setup`")
        end
      end

      def check_gitignore
        path = File.join(@project_dir, ".gitignore")
        unless File.exist?(path)
          fail!(".gitignore not found")
          return
        end
        content = File.read(path)
        missing = GITIGNORE_REQUIRED.reject { |l| content.include?(l) }
        if missing.empty?
          pass(".gitignore excludes sensitive files")
        else
          fail!(".gitignore is missing entries: #{missing.join(", ")}")
        end
      end

      def check_docker_running
        shell_run("docker", "info", chdir: @project_dir)
        pass("Docker is running")
      rescue TTY::Command::ExitError
        fail!("Docker is not running — start Docker Desktop and retry")
      end

      def check_kamal_config
        kamal_service.run("config")
        pass("Kamal configuration is valid")
      rescue Services::Kamal::Error
        fail!("Kamal configuration is invalid — check config/deploy.yml")
      end

      def check_git_history
        key = resolved_key
        return unless key
        out, = shell_run("git", "log", "--all", "-S", key, "--oneline", chdir: @project_dir)
        if out.strip.empty?
          pass("Licence key not found in git history")
        else
          fail!("Licence key may be committed in git history — run `git filter-repo` to remove it")
        end
      rescue TTY::Command::ExitError, Errno::ENOENT
        # git not available or not a git repo — skip silently
      end

      def check_licence_validity
        key = resolved_key
        return unless key
        uri = URI(GATEWAY_URL)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                   open_timeout: 10, read_timeout: 10) do |http|
          req = Net::HTTP::Get.new(uri)
          req.basic_auth("octobercms", key)
          http.request(req)
        end
        case response.code
        when "200" then pass("Licence key valid (gateway)")
        when "401" then fail!("Licence key rejected by gateway.octobercms.com")
        else            fail!("Unexpected response #{response.code} from gateway.octobercms.com")
        end
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT,
             Net::OpenTimeout, Net::ReadTimeout => e
        fail!("Could not reach gateway.octobercms.com (#{e.class})")
      end

      def kamal_service
        @kamal ||= Services::Kamal.new(project_dir: @project_dir, output: :null)
      end

      def shell_cmd
        @cmd ||= TTY::Command.new(printer: :null)
      end

      def shell_run(*args, **kwargs)
        shell_cmd.run(*args, **kwargs)
      end
    end
  end
end
