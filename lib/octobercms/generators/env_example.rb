require_relative "base"

module OctoberCMS
  module Generators
    class EnvExample
      include Base

      def initialize(context)
        @context = context
      end

      def render
        render_template("env.example.erb", @context)
      end

      def write(project_dir: Dir.pwd)
        path = File.join(project_dir, ".env.example")
        write_file(path, render)
        path
      end
    end
  end
end
