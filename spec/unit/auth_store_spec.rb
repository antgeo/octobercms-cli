require "tmpdir"
require_relative "../../lib/octobercms/services/auth_store"

RSpec.describe OctoberCMS::Services::AuthStore do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  # Point config_dir at tmpdir so tests never touch ~/.config
  let(:global_file) { File.join(tmpdir, "auth.yml") }

  before do
    allow(described_class).to receive(:config_dir).and_return(tmpdir)
    ENV.delete("OCTOBER_LICENCE_KEY")
  end

  after { ENV.delete("OCTOBER_LICENCE_KEY") }

  describe ".resolve" do
    context "OCTOBER_LICENCE_KEY env var is set" do
      it "returns source :env" do
        ENV["OCTOBER_LICENCE_KEY"] = "env-key"
        result = described_class.resolve(project_dir: tmpdir)
        expect(result).to eq({ key: "env-key", source: :env })
      end
    end

    context "no credential source exists" do
      it "returns nil" do
        expect(described_class.resolve(project_dir: tmpdir)).to be_nil
      end
    end

    context ".kamal/secrets contains OCTOBER_LICENCE_KEY" do
      before do
        dir = File.join(tmpdir, ".kamal")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "secrets"), "OCTOBER_LICENCE_KEY=project-key\nOTHER=val\n")
      end

      it "returns source :project with the key" do
        result = described_class.resolve(project_dir: tmpdir)
        expect(result).to eq({ key: "project-key", source: :project })
      end
    end

    context "only the global file exists" do
      before do
        File.write(global_file, "---\nlicence_key: global-key\n")
      end

      it "returns source :global with the key" do
        result = described_class.resolve(project_dir: tmpdir)
        expect(result).to eq({ key: "global-key", source: :global })
      end
    end

    context "priority order" do
      before do
        File.write(global_file, "---\nlicence_key: global-key\n")
        dir = File.join(tmpdir, ".kamal")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "secrets"), "OCTOBER_LICENCE_KEY=project-key\n")
      end

      it "prefers env var over project over global" do
        ENV["OCTOBER_LICENCE_KEY"] = "env-key"
        expect(described_class.resolve(project_dir: tmpdir)[:source]).to eq(:env)
      end

      it "prefers project over global" do
        result = described_class.resolve(project_dir: tmpdir)
        expect(result[:source]).to eq(:project)
        expect(result[:key]).to eq("project-key")
      end
    end
  end

  describe ".store_global" do
    it "writes auth.yml with mode 0600" do
      described_class.store_global("my-key")
      expect(File.exist?(global_file)).to be true
      expect(sprintf("%o", File.stat(global_file).mode & 0o777)).to eq("600")
    end

    it "stores the key under licence_key" do
      described_class.store_global("my-key")
      data = YAML.safe_load(File.read(global_file))
      expect(data["licence_key"]).to eq("my-key")
    end
  end

  describe ".store_project" do
    let(:secrets_path) { File.join(tmpdir, ".kamal", "secrets") }

    it "creates .kamal/secrets with mode 0600" do
      described_class.store_project("proj-key", project_dir: tmpdir)
      expect(File.exist?(secrets_path)).to be true
      expect(sprintf("%o", File.stat(secrets_path).mode & 0o777)).to eq("600")
    end

    it "writes the key line in quoted form" do
      described_class.store_project("proj-key", project_dir: tmpdir)
      expect(File.read(secrets_path)).to include('OCTOBER_LICENCE_KEY="proj-key"')
    end

    it "preserves existing lines" do
      FileUtils.mkdir_p(File.dirname(secrets_path))
      File.write(secrets_path, "DB_PASSWORD=secret\n")
      described_class.store_project("proj-key", project_dir: tmpdir)
      content = File.read(secrets_path)
      expect(content).to include("DB_PASSWORD=secret")
      expect(content).to include('OCTOBER_LICENCE_KEY="proj-key"')
    end

    it "replaces an existing OCTOBER_LICENCE_KEY line rather than duplicating" do
      FileUtils.mkdir_p(File.dirname(secrets_path))
      File.write(secrets_path, "OCTOBER_LICENCE_KEY=old-key\n")
      described_class.store_project("new-key", project_dir: tmpdir)
      lines = File.readlines(secrets_path).select { |l| l.start_with?("OCTOBER_LICENCE_KEY=") }
      expect(lines.size).to eq(1)
      expect(lines.first.strip).to eq('OCTOBER_LICENCE_KEY="new-key"')
    end

    it "does not corrupt the file when existing content has no trailing newline" do
      FileUtils.mkdir_p(File.dirname(secrets_path))
      File.write(secrets_path, "DB_PASSWORD=secret")  # no trailing newline
      described_class.store_project("proj-key", project_dir: tmpdir)
      content = File.read(secrets_path)
      expect(content).to include("DB_PASSWORD=secret\n")
      expect(content).to include('OCTOBER_LICENCE_KEY="proj-key"')
      # Ensure DB_PASSWORD line is not merged with the key line
      expect(content).not_to match(/DB_PASSWORD=secretOCTOBER/)
    end
  end

  describe ".remove_global" do
    it "deletes the global file" do
      File.write(global_file, "---\nlicence_key: key\n")
      described_class.remove_global
      expect(File.exist?(global_file)).to be false
    end

    it "is a no-op when file does not exist" do
      expect { described_class.remove_global }.not_to raise_error
    end
  end

  describe ".remove_project" do
    let(:secrets_path) { File.join(tmpdir, ".kamal", "secrets") }

    it "removes only the OCTOBER_LICENCE_KEY line" do
      FileUtils.mkdir_p(File.dirname(secrets_path))
      File.write(secrets_path, "DB_PASSWORD=secret\nOCTOBER_LICENCE_KEY=key\nOTHER=val\n")
      described_class.remove_project(project_dir: tmpdir)
      content = File.read(secrets_path)
      expect(content).not_to include("OCTOBER_LICENCE_KEY=")
      expect(content).to include("DB_PASSWORD=secret")
      expect(content).to include("OTHER=val")
    end

    it "is a no-op when secrets file does not exist" do
      expect { described_class.remove_project(project_dir: tmpdir) }.not_to raise_error
    end
  end
end
