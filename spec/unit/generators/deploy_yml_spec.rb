require "tmpdir"
require_relative "../../../lib/octobercms/generators/deploy_yml"

RSpec.describe OctoberCMS::Generators::DeployYml do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  let(:base_context) do
    {
      service:           "my-site",
      image:             "ghcr.io/org/my-site",
      servers:           ["1.2.3.4"],
      domain:            "example.com",
      registry_server:   "ghcr.io",
      registry_username: "org",
      mysql_accessory:   false,
      db_name:           "october",
      db_username:       "october",
      october_licence_key: nil,
    }
  end

  subject(:generator) { described_class.new(base_context) }

  describe "#render" do
    it "includes the service name" do
      expect(generator.render).to include("service: my-site")
    end

    it "includes the image" do
      expect(generator.render).to include("image: ghcr.io/org/my-site")
    end

    it "includes the server IP" do
      expect(generator.render).to include("- 1.2.3.4")
    end

    it "includes the domain in the proxy block" do
      expect(generator.render).to include("host: example.com")
    end

    it "includes the registry server when not Docker Hub" do
      expect(generator.render).to include("server: ghcr.io")
    end

    it "omits the registry server line for Docker Hub" do
      ctx = base_context.merge(registry_server: "docker.io")
      expect(described_class.new(ctx).render).not_to include("server: docker.io")
    end

    it "includes OCTOBER_LICENCE_KEY in builder.secrets" do
      expect(generator.render).to include("secrets:\n    - OCTOBER_LICENCE_KEY")
    end

    it "includes OCTOBER_LICENCE_KEY in env.secret" do
      expect(generator.render).to include("- OCTOBER_LICENCE_KEY")
    end

    context "with MySQL accessory" do
      let(:ctx) { base_context.merge(mysql_accessory: true) }

      it "includes the accessories block" do
        expect(described_class.new(ctx).render).to include("accessories:")
        expect(described_class.new(ctx).render).to include("image: mysql:8.0")
      end

      it "sets MYSQL_DATABASE to db_name" do
        expect(described_class.new(ctx).render).to include("MYSQL_DATABASE: october")
      end
    end

    context "without MySQL accessory" do
      it "omits the accessories block" do
        expect(generator.render).not_to include("accessories:")
      end
    end

    context "with multiple servers" do
      let(:ctx) { base_context.merge(servers: ["1.2.3.4", "5.6.7.8"]) }

      it "lists all server IPs" do
        rendered = described_class.new(ctx).render
        expect(rendered).to include("- 1.2.3.4")
        expect(rendered).to include("- 5.6.7.8")
      end
    end
  end

  describe "#write" do
    it "writes to config/deploy.yml" do
      generator.write(project_dir: tmpdir)
      expect(File.exist?(File.join(tmpdir, "config", "deploy.yml"))).to be true
    end

    it "creates the config directory if absent" do
      generator.write(project_dir: tmpdir)
      expect(File.directory?(File.join(tmpdir, "config"))).to be true
    end
  end
end
