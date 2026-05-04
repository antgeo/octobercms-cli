require "thor"
require_relative "doctor"
require_relative "../services/auth_store"
require_relative "../services/kamal"

module OctoberCMS
  module Commands
    class Deploy
      def initialize(options = {})
        @options     = options
        @project_dir = options.fetch(:project_dir, Dir.pwd)
        @kamal       = options[:kamal]
        @doctor      = options[:doctor]
      end

      def call
        pre_flight!
        puts ""
        kamal_service.run!("build", "push")
        migrate! unless @options[:skip_migrate]
        # kamal deploy rebuilds; layer cache keeps it fast. Replace with a
        # skip-push variant once the correct Kamal 2.x flag is confirmed.
        kamal_service.run!("deploy")
        puts "\nDeploy complete."
      end

      def build_only
        kamal_service.run!("build", "push")
      end

      def migrate_only
        migrate!
      end

      # H2: exec replaces the process so Kamal inherits the real TTY directly.
      # tty-command's pipe-based subprocess would break line editing and signal
      # forwarding for interactive sessions.
      def console
        exec("kamal", "app", "exec", "--interactive", "bash", chdir: @project_dir)
      end

      def logs
        args = ["app", "logs"]
        args << "--follow" unless @options[:no_follow]
        args << "--lines" << @options.fetch(:lines, 100).to_s
        kamal_service.run!(*args)
      end

      private

      def pre_flight!
        # M4: quiet suppresses per-check output during deploy; failures still
        # direct the user to run `octobercms doctor` for the full report.
        doctor = @doctor || Doctor.new(fast: true, quiet: true, project_dir: @project_dir)
        return if doctor.call
        raise Thor::Error, "Pre-flight checks failed. Run `octobercms doctor` for details."
      end

      def migrate!
        kamal_service.run!("app", "exec", "--reuse", "php artisan october:migrate")
      end

      def kamal_service
        @kamal ||= begin
          key = Services::AuthStore.resolve(project_dir: @project_dir)&.dig(:key)
          Services::Kamal.new(project_dir: @project_dir, licence_key: key, output: :pretty)
        end
      end
    end
  end
end
