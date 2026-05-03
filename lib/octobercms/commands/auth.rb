require "thor"
require "tty-prompt"
require "net/http"
require "uri"
require_relative "../services/auth_store"

module OctoberCMS
  module Commands
    class Auth < Thor
      GATEWAY_URL = "https://gateway.octobercms.com/packages.json"

      desc "setup", "Store the OctoberCMS licence key"
      def setup
        prompt = TTY::Prompt.new

        key = prompt.mask("OctoberCMS licence key:")
        raise Thor::Error, "Aborted." if key.nil? || key.strip.empty?
        key = key.strip

        scope = if Dir.exist?(File.join(Dir.pwd, ".kamal"))
          prompt.select("Store licence key:", ["For this project only", "Globally (default for all projects)"])
        else
          "Globally (default for all projects)"
        end

        puts "Validating licence key..."
        exit 1 unless validate_key(key) # validate_key already printed the specific reason

        if scope == "For this project only"
          Services::AuthStore.store_project(key)
          puts "Licence key stored for this project (.kamal/secrets)"
        else
          Services::AuthStore.store_global(key)
          puts "Licence key stored globally (~/.config/octobercms/auth.yml)"
        end
      end

      desc "status", "Show the active licence key source"
      option :validate, type: :boolean, default: false, desc: "Validate key with a project:set round-trip"
      def status
        result = Services::AuthStore.resolve
        raise Thor::Error, "No licence key configured. Run `octobercms auth setup`." unless result

        source_label = case result[:source]
                       when :env     then "env var (OCTOBER_LICENCE_KEY)"
                       when :project then "project (.kamal/secrets)"
                       when :global  then "global (~/.config/octobercms/auth.yml)"
                       else result[:source].to_s
                       end
        puts "Licence key active (source: #{source_label})"

        if options[:validate]
          puts "Validating..."
          exit 1 unless validate_key(result[:key]) # validate_key already printed the specific reason
          puts "Validation passed."
        end
      end

      desc "remove", "Remove the stored licence key"
      option :global, type: :boolean, default: false, desc: "Remove global key regardless of active source"
      def remove
        prompt = TTY::Prompt.new

        target = if options[:global]
          :global
        else
          result = Services::AuthStore.resolve
          unless result
            warn "No licence key configured."
            return
          end
          if result[:source] == :env
            warn "The active key is set via the OCTOBER_LICENCE_KEY environment variable and cannot be removed by this command."
            return
          end
          result[:source]
        end

        label = target == :global ? "global (~/.config/octobercms/auth.yml)" : "project (.kamal/secrets)"
        return unless prompt.yes?("Remove licence key from #{label}?")

        if target == :global
          Services::AuthStore.remove_global
        else
          Services::AuthStore.remove_project
        end
        puts "Licence key removed."
      end

      private

      def validate_key(key)
        uri = URI(GATEWAY_URL)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) do |http|
          req = Net::HTTP::Get.new(uri)
          req.basic_auth("octobercms", key)
          http.request(req)
        end

        case response.code
        when "200"
          true
        when "401"
          warn "Validation failed: licence key rejected by gateway.octobercms.com."
          false
        else
          warn "Validation failed: unexpected response #{response.code} from gateway.octobercms.com."
          false
        end
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout => e
        warn "Validation failed: could not reach gateway.octobercms.com (#{e.class})."
        warn "Check your network connection and try again."
        false
      rescue => e
        warn redact(e.message, key)
        false
      end

      def redact(text, key)
        return text if key.nil? || key.empty?
        text.gsub(key, "[REDACTED]")
      end
    end
  end
end
