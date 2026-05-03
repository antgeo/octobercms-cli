module OctoberCMS
  module Generators
    class Dockerignore
      LINES = %w[.git .gitignore .env auth.json .kamal/secrets vendor].freeze

      def initialize(_context = {})
      end

      def write(project_dir: Dir.pwd)
        path = File.join(project_dir, ".dockerignore")
        existing = File.exist?(path) ? File.read(path) : ""
        additions = LINES.reject { |l| existing.lines.any? { |el| el.chomp == l } }
        return false if additions.empty?
        existing += "\n" if !existing.empty? && !existing.end_with?("\n")
        File.write(path, existing + additions.join("\n") + "\n")
        true
      end
    end
  end
end
