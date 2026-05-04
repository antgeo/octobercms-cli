require_relative "base"

module OctoberCMS
  module Generators
    class Dockerfile
      include Base

      def initialize(context = {})
        @context = context
      end

      def render
        render_template("Dockerfile.erb", { php_version: "8.3" }.merge(@context))
      end

      def write(project_dir: Dir.pwd)
        path = File.join(project_dir, "Dockerfile")
        write_file(path, render)
        path
      end
    end
  end
end
