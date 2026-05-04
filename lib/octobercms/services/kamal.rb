require "tty-command"
require "thor"

module OctoberCMS
  module Services
    class Kamal
      Error = Class.new(RuntimeError)

      def initialize(project_dir: Dir.pwd, licence_key: nil, output: :pretty, cmd: nil)
        @project_dir = project_dir
        @redact      = licence_key.to_s
        @cmd         = cmd || TTY::Command.new(printer: output, color: true)
      end

      def run(*args)
        out, err = @cmd.run("kamal", *args, chdir: @project_dir)
        [redact(out), redact(err)]
      rescue TTY::Command::ExitError => e
        raise Error, redact(e.message)
      end

      def run!(*args)
        run(*args)
      rescue Error => e
        raise Thor::Error, e.message
      end

      private

      def redact(str)
        return str if @redact.empty?
        str.gsub(@redact, "[REDACTED]")
      end
    end
  end
end
