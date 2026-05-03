require "erb"
require "fileutils"

module OctoberCMS
  module Generators
    module Base
      TEMPLATE_DIR = File.expand_path("../templates", __dir__)

      def render_template(name, locals = {})
        path = File.join(TEMPLATE_DIR, name)
        ERB.new(File.read(path), trim_mode: "-").result_with_hash(locals)
      end

      def write_file(path, content, mode: 0o644)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp"
        begin
          File.write(tmp, content)
          File.chmod(mode, tmp)
          File.rename(tmp, path)
        rescue
          File.delete(tmp) if File.exist?(tmp)
          raise
        end
      end
    end
  end
end
