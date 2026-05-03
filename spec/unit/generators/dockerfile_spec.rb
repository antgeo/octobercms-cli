require "tmpdir"
require_relative "../../../lib/octobercms/generators/dockerfile"

RSpec.describe OctoberCMS::Generators::Dockerfile do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  subject(:generator) { described_class.new({}) }

  describe "#render" do
    it "includes the OctoberCMS runtime base image" do
      expect(generator.render).to include("FROM ghcr.io/antgeo/octobercms:php8.3")
    end

    it "mounts OCTOBER_LICENCE_KEY as a BuildKit secret" do
      expect(generator.render).to include("--mount=type=secret,id=OCTOBER_LICENCE_KEY")
    end

    it "runs project:set with the secret" do
      expect(generator.render).to include("php artisan project:set")
      expect(generator.render).to include("/run/secrets/OCTOBER_LICENCE_KEY")
    end

    it "runs composer install" do
      expect(generator.render).to include("composer install --no-dev")
    end

    it "uses the dockerfile:1.7 syntax directive" do
      expect(generator.render).to start_with("# syntax=docker/dockerfile:1.7")
    end
  end

  describe "#write" do
    it "writes Dockerfile to the project root" do
      generator.write(project_dir: tmpdir)
      expect(File.exist?(File.join(tmpdir, "Dockerfile"))).to be true
    end

    it "writes the correct content" do
      generator.write(project_dir: tmpdir)
      expect(File.read(File.join(tmpdir, "Dockerfile"))).to include("FROM ghcr.io/antgeo/octobercms:php8.3")
    end
  end
end
