require_relative "base"

module OctoberCMS
  module Generators
    class Secrets
      include Base

      def initialize(context)
        @context = context
      end

      def render
        render_template("secrets.erb", @context)
      end

      def write(project_dir: Dir.pwd)
        path = File.join(project_dir, ".kamal", "secrets")
        write_file(path, render, mode: 0o600)
        path
      end
    end
  end
end
