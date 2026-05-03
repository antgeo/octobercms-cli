require "fileutils"
require "yaml"

module OctoberCMS
  module Services
    module AuthStore
      def self.config_dir
        File.expand_path("~/.config/octobercms")
      end

      def self.global_file
        File.join(config_dir, "auth.yml")
      end

      # Returns {key: String, source: Symbol} or nil.
      # Sources (priority order): :env | :project | :global
      def self.resolve(project_dir: Dir.pwd)
        key = ENV["OCTOBER_LICENCE_KEY"].to_s
        return { key: key, source: :env } unless key.empty?

        secrets_file = File.join(project_dir, ".kamal", "secrets")
        if File.exist?(secrets_file)
          key = read_secrets_key(secrets_file)
          return { key: key, source: :project } if key
        end

        if File.exist?(global_file)
          key = read_global_key
          return { key: key, source: :global } if key
        end

        nil
      end

      def self.store_global(key)
        FileUtils.mkdir_p(config_dir, mode: 0o700)
        tmp = global_file + ".tmp"
        File.write(tmp, YAML.dump({ "licence_key" => key }))
        File.chmod(0o600, tmp)
        File.rename(tmp, global_file)
      end

      def self.store_project(key, project_dir: Dir.pwd)
        secrets_path = File.join(project_dir, ".kamal", "secrets")
        FileUtils.mkdir_p(File.dirname(secrets_path), mode: 0o700)
        existing = File.exist?(secrets_path) ? File.read(secrets_path) : ""
        cleaned  = existing.lines.reject { |l| l.match?(/^OCTOBER_LICENCE_KEY=/) }.join
        cleaned += "\n" if !cleaned.empty? && !cleaned.end_with?("\n")
        tmp = secrets_path + ".tmp"
        File.write(tmp, "#{cleaned}OCTOBER_LICENCE_KEY=\"#{key}\"\n")
        File.chmod(0o600, tmp)
        File.rename(tmp, secrets_path)
      end

      def self.remove_global
        File.delete(global_file) if File.exist?(global_file)
      end

      def self.remove_project(project_dir: Dir.pwd)
        secrets_path = File.join(project_dir, ".kamal", "secrets")
        return unless File.exist?(secrets_path)
        cleaned = File.read(secrets_path).lines.reject { |l| l.match?(/^OCTOBER_LICENCE_KEY=/) }.join
        File.write(secrets_path, cleaned)
      end

      private_class_method def self.read_secrets_key(path)
        File.readlines(path).each do |line|
          m = line.match(/^OCTOBER_LICENCE_KEY=(.+)$/)
          next unless m
          # Strip surrounding quotes written by store_project; also accept unquoted values.
          val = m[1].strip.delete_prefix('"').delete_suffix('"')
          return val unless val.empty?
        end
        nil
      end

      private_class_method def self.read_global_key
        data = YAML.safe_load(File.read(global_file)) rescue nil
        data&.dig("licence_key")
      end
    end
  end
end
