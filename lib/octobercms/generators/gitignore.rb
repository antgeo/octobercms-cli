require "fileutils"

module OctoberCMS
  module Generators
    class Gitignore
      LINES = %w[auth.json .env .kamal/secrets].freeze

      def initialize(_context = {})
      end

      def write(project_dir: Dir.pwd)
        path = File.join(project_dir, ".gitignore")
        existing = File.exist?(path) ? File.read(path) : ""
        additions = LINES.reject { |l| existing.lines.any? { |el| el.chomp == l } }
        return path if additions.empty?
        existing += "\n" if !existing.empty? && !existing.end_with?("\n")
        File.write(path, existing + additions.join("\n") + "\n")
        path
      end
    end
  end
end
