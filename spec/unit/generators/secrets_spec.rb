require "tmpdir"
require_relative "../../../lib/octobercms/generators/secrets"

RSpec.describe OctoberCMS::Generators::Secrets do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  let(:base_context) do
    {
      domain:              "example.com",
      db_name:             "october",
      db_username:         "october",
      mysql_accessory:     false,
      october_licence_key: nil,
    }
  end

  subject(:generator) { described_class.new(base_context) }

  describe "#render" do
    it "includes KAMAL_REGISTRY_PASSWORD placeholder" do
      expect(generator.render).to include("KAMAL_REGISTRY_PASSWORD=")
    end

    it "includes APP_URL with domain" do
      expect(generator.render).to include("APP_URL=https://example.com")
    end

    it "includes DB_DATABASE" do
      expect(generator.render).to include("DB_DATABASE=october")
    end

    context "when october_licence_key is set" do
      let(:ctx) { base_context.merge(october_licence_key: "my-secret-key") }

      it "writes the key in quoted form" do
        expect(described_class.new(ctx).render).to include('OCTOBER_LICENCE_KEY="my-secret-key"')
      end
    end

    context "when october_licence_key is nil" do
      it "writes a blank OCTOBER_LICENCE_KEY line" do
        expect(generator.render).to include("OCTOBER_LICENCE_KEY=\n")
      end
    end

    context "with MySQL accessory" do
      let(:ctx) { base_context.merge(mysql_accessory: true) }

      it "includes MYSQL_ROOT_PASSWORD" do
        expect(described_class.new(ctx).render).to include("MYSQL_ROOT_PASSWORD=")
      end
    end

    context "without MySQL accessory" do
      it "omits MYSQL_ROOT_PASSWORD" do
        expect(generator.render).not_to include("MYSQL_ROOT_PASSWORD")
      end
    end
  end

  describe "#write" do
    it "writes to .kamal/secrets" do
      generator.write(project_dir: tmpdir)
      expect(File.exist?(File.join(tmpdir, ".kamal", "secrets"))).to be true
    end

    it "writes with mode 0600" do
      generator.write(project_dir: tmpdir)
      mode = File.stat(File.join(tmpdir, ".kamal", "secrets")).mode & 0o777
      expect(sprintf("%o", mode)).to eq("600")
    end
  end
end
