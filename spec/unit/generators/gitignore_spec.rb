require "tmpdir"
require_relative "../../../lib/octobercms/generators/gitignore"

RSpec.describe OctoberCMS::Generators::Gitignore do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  subject(:generator) { described_class.new }

  describe "#write" do
    context "when .gitignore does not exist" do
      it "creates the file" do
        generator.write(project_dir: tmpdir)
        expect(File.exist?(File.join(tmpdir, ".gitignore"))).to be true
      end

      it "writes all required lines" do
        generator.write(project_dir: tmpdir)
        content = File.read(File.join(tmpdir, ".gitignore"))
        expect(content).to include("auth.json")
        expect(content).to include(".env")
        expect(content).to include(".kamal/secrets")
      end
    end

    context "when .gitignore exists with other content" do
      before do
        File.write(File.join(tmpdir, ".gitignore"), "*.log\nnode_modules/\n")
      end

      it "preserves existing content" do
        generator.write(project_dir: tmpdir)
        content = File.read(File.join(tmpdir, ".gitignore"))
        expect(content).to include("*.log")
        expect(content).to include("node_modules/")
      end

      it "appends the required lines" do
        generator.write(project_dir: tmpdir)
        content = File.read(File.join(tmpdir, ".gitignore"))
        expect(content).to include("auth.json")
        expect(content).to include(".kamal/secrets")
      end
    end

    context "when .gitignore already contains the required lines" do
      before do
        File.write(File.join(tmpdir, ".gitignore"), "auth.json\n.env\n.kamal/secrets\n")
      end

      it "does not duplicate existing lines" do
        generator.write(project_dir: tmpdir)
        content = File.read(File.join(tmpdir, ".gitignore"))
        expect(content.scan("auth.json").size).to eq(1)
        expect(content.scan(".kamal/secrets").size).to eq(1)
      end
    end

    context "when .gitignore has no trailing newline" do
      before do
        File.write(File.join(tmpdir, ".gitignore"), "*.log")
      end

      it "does not merge the last existing line with the first addition" do
        generator.write(project_dir: tmpdir)
        content = File.read(File.join(tmpdir, ".gitignore"))
        expect(content).to match(/\*\.log\nauth\.json/)
      end
    end
  end
end
