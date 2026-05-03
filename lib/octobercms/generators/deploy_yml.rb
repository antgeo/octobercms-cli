require_relative "base"

module OctoberCMS
  module Generators
    class DeployYml
      include Base

      def initialize(context)
        @context = context
      end

      def render
        render_template("deploy.yml.erb", @context)
      end

      def write(project_dir: Dir.pwd)
        path = File.join(project_dir, "config", "deploy.yml")
        write_file(path, render)
        path
      end
    end
  end
end
