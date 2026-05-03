require "tmpdir"
require_relative "../../../lib/octobercms/generators/dockerignore"

RSpec.describe OctoberCMS::Generators::Dockerignore do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  subject(:generator) { described_class.new }

  describe "#write" do
    it "creates .dockerignore when absent" do
      generator.write(project_dir: tmpdir)
      expect(File.exist?(File.join(tmpdir, ".dockerignore"))).to be true
    end

    it "includes essential entries" do
      generator.write(project_dir: tmpdir)
      content = File.read(File.join(tmpdir, ".dockerignore"))
      expect(content).to include(".git")
      expect(content).to include(".env")
      expect(content).to include("vendor")
      expect(content).to include(".kamal/secrets")
    end

    it "returns true when entries were added" do
      expect(generator.write(project_dir: tmpdir)).to be true
    end

    it "returns false when all entries are already present" do
      generator.write(project_dir: tmpdir)
      expect(generator.write(project_dir: tmpdir)).to be false
    end

    it "appends missing lines to an existing .dockerignore" do
      path = File.join(tmpdir, ".dockerignore")
      File.write(path, ".git\n")
      generator.write(project_dir: tmpdir)
      content = File.read(path)
      expect(content).to include("vendor")
      expect(content.lines.count { |l| l.chomp == ".git" }).to eq(1)
    end

    it "does not duplicate lines already present" do
      path = File.join(tmpdir, ".dockerignore")
      File.write(path, ".git\nvendor\n")
      generator.write(project_dir: tmpdir)
      content = File.read(path)
      expect(content.scan("vendor").count).to eq(1)
    end
  end
end
