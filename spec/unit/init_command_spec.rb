require "tmpdir"
require "stringio"
require_relative "../../lib/octobercms/commands/init"

RSpec.describe OctoberCMS::Commands::Init do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  def run(&block)
    out_io = StringIO.new
    err_io = StringIO.new
    old_out, old_err = $stdout, $stderr
    $stdout = out_io
    $stderr = err_io
    return_val = block.call
    { out: out_io.string, err: err_io.string, code: 0, return_val: return_val }
  rescue Thor::Error => e
    $stderr.puts e.message unless e.message.to_s.empty?
    { out: out_io.string, err: err_io.string, code: 1, return_val: nil }
  rescue SystemExit => e
    { out: out_io.string, err: err_io.string, code: e.status, return_val: nil }
  ensure
    $stdout = old_out
    $stderr = old_err
  end

  let(:full_context) do
    {
      service:             "my-site",
      image:               "ghcr.io/org/my-site",
      servers:             ["1.2.3.4"],
      domain:              "example.com",
      registry_server:     "ghcr.io",
      registry_username:   "org",
      mysql_accessory:     true,
      db_name:             "october",
      db_username:         "october",
      october_licence_key: "test-key",
    }
  end

  let(:prompt) { instance_double(TTY::Prompt) }

  before do
    allow(TTY::Prompt).to receive(:new).and_return(prompt)
    allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return(
      { key: "test-key", source: :project }
    )
    allow(OctoberCMS::Services::AuthStore).to receive(:store_project)
    ENV.delete("OCTOBER_LICENCE_KEY")
  end

  after { ENV.delete("OCTOBER_LICENCE_KEY") }

  # ── project detection ──────────────────────────────────────────────────────

  describe "#call — project detection" do
    it "errors when composer.json is missing" do
      Dir.chdir(tmpdir) do
        File.write(File.join(tmpdir, "artisan"), "")
        result = run { described_class.new.call }
        expect(result[:code]).to eq(1)
        expect(result[:err]).to include("No OctoberCMS project found")
        expect(result[:err]).to include("composer.json")
      end
    end

    it "errors when artisan is missing" do
      Dir.chdir(tmpdir) do
        File.write(File.join(tmpdir, "composer.json"), "{}")
        result = run { described_class.new.call }
        expect(result[:code]).to eq(1)
        expect(result[:err]).to include("artisan")
      end
    end

    it "errors when both files are missing" do
      Dir.chdir(tmpdir) do
        result = run { described_class.new.call }
        expect(result[:code]).to eq(1)
        expect(result[:err]).to include("No OctoberCMS project found")
      end
    end
  end

  # ── licence key resolution ─────────────────────────────────────────────────

  describe "#call — licence key resolution" do
    before do
      File.write(File.join(tmpdir, "composer.json"), "{}")
      File.write(File.join(tmpdir, "artisan"), "")
      # Bypass gather/generate so tests focus on resolve_key
      allow_any_instance_of(described_class).to receive(:gather_context).and_return(full_context)
      allow_any_instance_of(described_class).to receive(:generate_files)
    end

    context "when key source is :env" do
      before do
        allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return(
          { key: "env-key", source: :env }
        )
      end

      it "notes the env var and does not store to project" do
        Dir.chdir(tmpdir) do
          result = run { described_class.new.call }
          expect(result[:out]).to include("OCTOBER_LICENCE_KEY env var")
          expect(OctoberCMS::Services::AuthStore).not_to have_received(:store_project)
        end
      end
    end

    context "when key source is :project" do
      it "notes the key is already set" do
        Dir.chdir(tmpdir) do
          result = run { described_class.new.call }
          expect(result[:out]).to include("already set for this project")
        end
      end
    end

    context "when key source is :global and user confirms copy" do
      before do
        allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return(
          { key: "global-key", source: :global }
        )
        allow(OctoberCMS::Services::AuthStore).to receive(:store_project)
        allow(prompt).to receive(:yes?).with(/Copy global/, any_args).and_return(true)
      end

      it "calls store_project with the key" do
        Dir.chdir(tmpdir) do
          run { described_class.new.call }
          expect(OctoberCMS::Services::AuthStore).to have_received(:store_project)
            .with("global-key", project_dir: File.realpath(tmpdir))
        end
      end
    end

    context "when key source is :global and user declines copy" do
      before do
        allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return(
          { key: "global-key", source: :global }
        )
        allow(prompt).to receive(:yes?).with(/Copy global/, any_args).and_return(false)
      end

      it "does not call store_project" do
        Dir.chdir(tmpdir) do
          run { described_class.new.call }
          expect(OctoberCMS::Services::AuthStore).not_to have_received(:store_project)
        end
      end
    end

    context "when no key is configured" do
      before do
        allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return(nil, nil)
        allow_any_instance_of(described_class).to receive(:run_auth_setup)
      end

      it "calls run_auth_setup" do
        Dir.chdir(tmpdir) do
          cmd = described_class.new
          run { cmd.call }
          expect(cmd).to have_received(:run_auth_setup)
        end
      end

      it "warns when key is still nil after auth setup" do
        Dir.chdir(tmpdir) do
          result = run { described_class.new.call }
          expect(result[:err]).to include("Warning: no licence key configured")
        end
      end
    end
  end

  # ── file generation ────────────────────────────────────────────────────────

  describe "#call — file generation" do
    before do
      File.write(File.join(tmpdir, "composer.json"), "{}")
      File.write(File.join(tmpdir, "artisan"), "")
      stub_prompts_with_full_context
    end

    it "creates all six output files" do
      Dir.chdir(tmpdir) do
        run { described_class.new.call }
        expect(File.exist?(File.join(tmpdir, "Dockerfile"))).to be true
        expect(File.exist?(File.join(tmpdir, "config", "deploy.yml"))).to be true
        expect(File.exist?(File.join(tmpdir, ".kamal", "secrets"))).to be true
        expect(File.exist?(File.join(tmpdir, ".env.example"))).to be true
        expect(File.exist?(File.join(tmpdir, ".gitignore"))).to be true
        expect(File.exist?(File.join(tmpdir, ".dockerignore"))).to be true
      end
    end

    it "prints create/update lines for each file" do
      Dir.chdir(tmpdir) do
        result = run { described_class.new.call }
        expect(result[:out]).to include("create  Dockerfile")
        expect(result[:out]).to include("create  config/deploy.yml")
        expect(result[:out]).to include("create  .kamal/secrets")
        expect(result[:out]).to include("create  .env.example")
        expect(result[:out]).to include("update  .gitignore")
        expect(result[:out]).to include("update  .dockerignore")
      end
    end

    context "when a file already exists and --skip-existing is set" do
      it "skips without prompting" do
        Dir.chdir(tmpdir) do
          File.write(File.join(tmpdir, "Dockerfile"), "existing")
          result = run { described_class.new(skip_existing: true).call }
          expect(result[:out]).to include("skip    Dockerfile")
          expect(File.read(File.join(tmpdir, "Dockerfile"))).to eq("existing")
        end
      end
    end

    context "when a file already exists and user declines overwrite" do
      before do
        allow(prompt).to receive(:yes?) do |msg, **_opts|
          msg.include?("Overwrite") ? false : true
        end
      end

      it "skips the file" do
        Dir.chdir(tmpdir) do
          File.write(File.join(tmpdir, "Dockerfile"), "existing")
          result = run { described_class.new.call }
          expect(result[:out]).to include("skip    Dockerfile")
          expect(File.read(File.join(tmpdir, "Dockerfile"))).to eq("existing")
        end
      end
    end

    context "when a file already exists and user confirms overwrite" do
      before do
        allow(prompt).to receive(:yes?) do |msg, **_opts|
          msg.include?("Overwrite") ? true : false
        end
      end

      it "overwrites the file" do
        Dir.chdir(tmpdir) do
          File.write(File.join(tmpdir, "Dockerfile"), "old content")
          run { described_class.new.call }
          expect(File.read(File.join(tmpdir, "Dockerfile"))).to include("ghcr.io/antgeo/octobercms")
        end
      end
    end

    context "when multiple server IPs are provided" do
      before do
        call_count = 0
        allow(prompt).to receive(:ask) do |msg, **_opts|
          case msg
          when /App name/          then "my-site"
          when /Registry username/ then "org"
          when /Docker image/      then "ghcr.io/org/my-site"
          when /Server IP/         then "1.2.3.4"
          when /Another server/
            call_count += 1
            call_count == 1 ? "5.6.7.8" : ""
          when /Domain/            then "example.com"
          when /Database name/     then "october"
          when /Database username/ then "october"
          end
        end
        allow(prompt).to receive(:select) do |msg, _choices|
          case msg
          when /registry/i then "GitHub Container Registry (ghcr.io)"
          when /Database/  then "Built-in MySQL accessory"
          end
        end
        allow(prompt).to receive(:yes?).and_return(false)
      end

      it "includes all server IPs in deploy.yml" do
        Dir.chdir(tmpdir) do
          run { described_class.new.call }
          content = File.read(File.join(tmpdir, "config", "deploy.yml"))
          expect(content).to include("1.2.3.4")
          expect(content).to include("5.6.7.8")
        end
      end
    end

    context "when .gitignore and .dockerignore already contain all required lines" do
      before do
        File.write(File.join(tmpdir, ".gitignore"), "auth.json\n.env\n.kamal/secrets\n")
        File.write(File.join(tmpdir, ".dockerignore"),
                   ".git\n.gitignore\n.env\nauth.json\n.kamal/secrets\nvendor\n")
      end

      it "prints skip for both ignore files" do
        Dir.chdir(tmpdir) do
          result = run { described_class.new.call }
          expect(result[:out]).to include("skip    .gitignore")
          expect(result[:out]).to include("skip    .dockerignore")
        end
      end
    end
  end

  private

  def stub_prompts_with_full_context
    allow(prompt).to receive(:ask) do |msg, **_opts|
      case msg
      when /App name/          then "my-site"
      when /Registry username/ then "org"
      when /Docker image/      then "ghcr.io/org/my-site"
      when /Server IP/         then "1.2.3.4"
      when /Another server/    then ""
      when /Domain/            then "example.com"
      when /Database name/     then "october"
      when /Database username/ then "october"
      when /Registry server/   then "registry.example.com"
      end
    end
    allow(prompt).to receive(:select) do |msg, _choices|
      case msg
      when /registry/i   then "GitHub Container Registry (ghcr.io)"
      when /Database/    then "Built-in MySQL accessory"
      end
    end
    allow(prompt).to receive(:yes?).and_return(false)
  end
end
