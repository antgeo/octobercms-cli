require "tmpdir"
require_relative "../../../lib/octobercms/generators/env_example"

RSpec.describe OctoberCMS::Generators::EnvExample do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  let(:context) do
    {
      domain:      "example.com",
      db_name:     "october",
      db_username: "october",
    }
  end

  subject(:generator) { described_class.new(context) }

  describe "#render" do
    it "includes APP_URL with domain" do
      expect(generator.render).to include("APP_URL=https://example.com")
    end

    it "includes DB_DATABASE" do
      expect(generator.render).to include("DB_DATABASE=october")
    end

    it "includes DB_USERNAME" do
      expect(generator.render).to include("DB_USERNAME=october")
    end

    it "includes MAIL_FROM_ADDRESS with domain" do
      expect(generator.render).to include("MAIL_FROM_ADDRESS=hello@example.com")
    end

    it "does not contain any ERB tags in the output" do
      expect(generator.render).not_to include("<%")
    end
  end

  describe "#write" do
    it "writes to .env.example" do
      generator.write(project_dir: tmpdir)
      expect(File.exist?(File.join(tmpdir, ".env.example"))).to be true
    end
  end
end
