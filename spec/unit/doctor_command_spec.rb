require "tmpdir"
require "stringio"
require_relative "../../lib/octobercms/commands/doctor"

RSpec.describe OctoberCMS::Commands::Doctor do
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

  def write_valid_project
    FileUtils.mkdir_p(File.join(tmpdir, "config"))
    File.write(File.join(tmpdir, "config", "deploy.yml"), "service: myapp\n")
    FileUtils.mkdir_p(File.join(tmpdir, ".kamal"))
    secrets = <<~SECRETS
      KAMAL_REGISTRY_PASSWORD=pass
      OCTOBER_LICENCE_KEY="test-key"
      APP_KEY=base64:abc
      DB_DATABASE=october
      DB_USERNAME=october
      DB_PASSWORD=secret
    SECRETS
    File.write(File.join(tmpdir, ".kamal", "secrets"), secrets)
    File.write(File.join(tmpdir, ".gitignore"), "auth.json\n.env\n.kamal/secrets\n")
  end

  before do
    allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return(
      { key: "test-key", source: :project }
    )
    ENV.delete("OCTOBER_LICENCE_KEY")
  end
  after { ENV.delete("OCTOBER_LICENCE_KEY") }

  # ── fast mode (local checks only) ─────────────────────────────────────────

  describe "#call — fast mode" do
    subject(:doctor) { described_class.new(project_dir: tmpdir, fast: true) }

    context "when all local checks pass" do
      before { write_valid_project }

      it "returns true" do
        result = run { doctor.call }
        expect(result[:return_val]).to be true
      end

      it "prints ✓ for each check and no ✗" do
        result = run { doctor.call }
        expect(result[:out]).to include("✓")
        expect(result[:out]).not_to include("✗")
      end
    end

    context "when config/deploy.yml is missing" do
      before do
        write_valid_project
        File.delete(File.join(tmpdir, "config", "deploy.yml"))
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end

      it "prints ✗ mentioning deploy.yml" do
        result = run { doctor.call }
        expect(result[:out]).to include("✗")
        expect(result[:out]).to include("deploy.yml")
      end
    end

    context "when .kamal/secrets is missing" do
      before do
        write_valid_project
        File.delete(File.join(tmpdir, ".kamal", "secrets"))
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end
    end

    context "when .kamal/secrets is missing a required key value" do
      before do
        write_valid_project
        File.write(File.join(tmpdir, ".kamal", "secrets"), "KAMAL_REGISTRY_PASSWORD=pass\n")
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end

      it "names the missing key" do
        result = run { doctor.call }
        expect(result[:out]).to include("OCTOBER_LICENCE_KEY")
      end
    end

    context "when .kamal/secrets has an empty quoted value (M5)" do
      before do
        write_valid_project
        File.write(File.join(tmpdir, ".kamal", "secrets"),
                   "KAMAL_REGISTRY_PASSWORD=pass\nOCTOBER_LICENCE_KEY=\"\"\n")
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end

      it "reports the key with empty value as missing" do
        result = run { doctor.call }
        expect(result[:out]).to include("OCTOBER_LICENCE_KEY")
      end
    end

    context "when no licence key is configured" do
      before do
        write_valid_project
        allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return(nil)
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end

      it "prints ✗ mentioning auth setup" do
        result = run { doctor.call }
        expect(result[:out]).to include("auth setup")
      end
    end

    context "when .gitignore is missing required entries" do
      before do
        write_valid_project
        File.write(File.join(tmpdir, ".gitignore"), "*.log\n")
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end

      it "names the missing entries" do
        result = run { doctor.call }
        expect(result[:out]).to include("auth.json")
      end
    end

    context "when .gitignore is absent" do
      before do
        write_valid_project
        File.delete(File.join(tmpdir, ".gitignore"))
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end
    end

    context "in quiet mode (M4)" do
      subject(:doctor) { described_class.new(project_dir: tmpdir, fast: true, quiet: true) }

      before { write_valid_project }

      it "produces no output when all checks pass" do
        result = run { doctor.call }
        expect(result[:out]).to be_empty
      end

      it "produces no output when a check fails" do
        File.delete(File.join(tmpdir, "config", "deploy.yml"))
        result = run { doctor.call }
        expect(result[:out]).to be_empty
      end

      it "still returns false when a check fails" do
        File.delete(File.join(tmpdir, "config", "deploy.yml"))
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end
    end
  end

  # ── full mode (includes shell-out checks) ─────────────────────────────────

  describe "#call — full mode" do
    let(:mock_kamal) { instance_double(OctoberCMS::Services::Kamal) }
    let(:mock_cmd)   { instance_double(TTY::Command) }
    subject(:doctor) do
      described_class.new(project_dir: tmpdir, kamal: mock_kamal, cmd: mock_cmd)
    end

    before do
      write_valid_project
      allow(mock_cmd).to receive(:run).and_return(["", ""])
      allow(mock_kamal).to receive(:run).and_return(["", ""])
    end

    it "checks that Docker is running" do
      run { doctor.call }
      expect(mock_cmd).to have_received(:run).with("docker", "info", chdir: tmpdir)
    end

    it "validates kamal config" do
      run { doctor.call }
      expect(mock_kamal).to have_received(:run).with("config")
    end

    context "when Docker is not running" do
      let(:exit_result) { double("result", exit_status: 1, out: "", err: "Cannot connect") }

      before do
        allow(mock_cmd).to receive(:run)
          .with("docker", "info", chdir: tmpdir)
          .and_raise(TTY::Command::ExitError.new("docker info", exit_result))
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end

      it "prints ✗ mentioning Docker" do
        result = run { doctor.call }
        expect(result[:out]).to include("Docker")
      end
    end

    context "when kamal config is invalid" do
      before do
        allow(mock_kamal).to receive(:run)
          .and_raise(OctoberCMS::Services::Kamal::Error.new("invalid config"))
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end

      it "prints ✗ mentioning invalid config" do
        result = run { doctor.call }
        expect(result[:out]).to include("invalid")
      end
    end

    context "when the licence key is found in git history" do
      before do
        allow(mock_cmd).to receive(:run)
          .with("git", "log", "--all", "-S", "test-key", "--oneline", chdir: tmpdir)
          .and_return(["abc123 Oops committed secrets\n", ""])
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end

      it "prints ✗ mentioning git history" do
        result = run { doctor.call }
        expect(result[:out]).to include("git history")
      end
    end
  end

  # ── --validate flag ────────────────────────────────────────────────────────

  describe "#call — with --validate" do
    let(:mock_kamal) { instance_double(OctoberCMS::Services::Kamal) }
    let(:mock_cmd)   { instance_double(TTY::Command) }
    subject(:doctor) do
      described_class.new(project_dir: tmpdir, validate: true, kamal: mock_kamal, cmd: mock_cmd)
    end

    before do
      write_valid_project
      allow(mock_cmd).to receive(:run).and_return(["", ""])
      allow(mock_kamal).to receive(:run).and_return(["", ""])
    end

    context "when gateway returns 200" do
      before do
        allow(Net::HTTP).to receive(:start).and_yield(
          instance_double(Net::HTTP, request: double("response", code: "200"))
        )
      end

      it "passes the licence validity check" do
        result = run { doctor.call }
        expect(result[:out]).to include("valid")
        expect(result[:out]).not_to match(/✗.*valid/)
      end
    end

    context "when gateway returns 401" do
      before do
        allow(Net::HTTP).to receive(:start).and_yield(
          instance_double(Net::HTTP, request: double("response", code: "401"))
        )
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end

      it "prints ✗ mentioning rejected" do
        result = run { doctor.call }
        expect(result[:out]).to include("rejected")
      end
    end

    context "when gateway is unreachable" do
      before do
        allow(Net::HTTP).to receive(:start).and_raise(SocketError, "getaddrinfo failed")
      end

      it "returns false" do
        result = run { doctor.call }
        expect(result[:return_val]).to be false
      end

      it "prints ✗ mentioning the gateway" do
        result = run { doctor.call }
        expect(result[:out]).to include("gateway.octobercms.com")
      end
    end
  end
end
