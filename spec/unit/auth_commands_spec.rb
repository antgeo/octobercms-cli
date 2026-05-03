require "tmpdir"
require "stringio"
require "base64"
require_relative "../../lib/octobercms/commands/auth"

RSpec.describe OctoberCMS::Commands::Auth do
  # Runs the block capturing stdout, stderr, exit code, and return value.
  # Handles both Thor::Error (idiomatic CLI errors) and SystemExit.
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

  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  before do
    allow(OctoberCMS::Services::AuthStore).to receive(:config_dir).and_return(tmpdir)
    ENV.delete("OCTOBER_LICENCE_KEY")
  end
  after { ENV.delete("OCTOBER_LICENCE_KEY") }

  let(:prompt) { instance_double(TTY::Prompt) }
  before { allow(TTY::Prompt).to receive(:new).and_return(prompt) }

  # ── auth status ─────────────────────────────────────────────────────────────

  describe "#status" do
    def cmd(opts = {})
      described_class.new([], opts)
    end

    context "no key is configured" do
      before { allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return(nil) }

      it "exits 1" do
        expect(run { cmd.status }[:code]).to eq(1)
      end

      it "prints an error message to stderr" do
        expect(run { cmd.status }[:err]).to include("No licence key configured")
      end

      it "suggests running auth setup" do
        expect(run { cmd.status }[:err]).to include("auth setup")
      end
    end

    context "key resolved from env var" do
      before { allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return({ key: "k", source: :env }) }

      it "exits 0" do
        expect(run { cmd.status }[:code]).to eq(0)
      end

      it "prints the env var source" do
        expect(run { cmd.status }[:out]).to include("env var (OCTOBER_LICENCE_KEY)")
      end
    end

    context "key resolved from project (.kamal/secrets)" do
      before { allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return({ key: "k", source: :project }) }

      it "prints the project source" do
        expect(run { cmd.status }[:out]).to include("project (.kamal/secrets)")
      end
    end

    context "key resolved from global file" do
      before { allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return({ key: "k", source: :global }) }

      it "prints the global source" do
        expect(run { cmd.status }[:out]).to include("global (~/.config/octobercms/auth.yml)")
      end
    end

    context "--validate flag" do
      let(:instance) { described_class.new([], { "validate" => true }) }

      before { allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return({ key: "k", source: :global }) }

      it "prints 'Validation passed.' when the key is valid" do
        allow(instance).to receive(:validate_key).and_return(true)
        expect(run { instance.status }[:out]).to include("Validation passed.")
      end

      it "exits 1 when validation fails" do
        allow(instance).to receive(:validate_key).and_return(false)
        expect(run { instance.status }[:code]).to eq(1)
      end

      it "does not print 'Validation passed.' when validation fails" do
        allow(instance).to receive(:validate_key).and_return(false)
        expect(run { instance.status }[:out]).not_to include("Validation passed.")
      end
    end

    it "skips validation when --validate is not passed" do
      allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return({ key: "k", source: :global })
      instance = cmd
      expect(instance).not_to receive(:validate_key)
      run { instance.status }
    end
  end

  # ── auth setup ──────────────────────────────────────────────────────────────

  describe "#setup" do
    subject { described_class.new([], {}) }

    # Prevent real Docker calls in all setup tests
    before { allow(subject).to receive(:validate_key).and_return(true) }

    context "user enters an empty key" do
      before { allow(prompt).to receive(:mask).and_return("") }

      it "exits 1" do
        expect(run { subject.setup }[:code]).to eq(1)
      end

      it "prints 'Aborted' to stderr" do
        expect(run { subject.setup }[:err]).to include("Aborted")
      end

      it "does not store anything" do
        expect(OctoberCMS::Services::AuthStore).not_to receive(:store_global)
        expect(OctoberCMS::Services::AuthStore).not_to receive(:store_project)
        run { subject.setup }
      end
    end

    context "user enters a nil key (e.g. Ctrl-C)" do
      before { allow(prompt).to receive(:mask).and_return(nil) }

      it "exits 1" do
        expect(run { subject.setup }[:code]).to eq(1)
      end
    end

    context "no .kamal/ directory (not inside a project)" do
      before do
        allow(prompt).to receive(:mask).and_return("my-licence-key")
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with(a_string_ending_with("/.kamal")).and_return(false)
        allow(OctoberCMS::Services::AuthStore).to receive(:store_global)
      end

      it "stores the key globally without asking for scope" do
        expect(prompt).not_to receive(:select)
        run { subject.setup }
      end

      it "calls store_global with the entered key" do
        expect(OctoberCMS::Services::AuthStore).to receive(:store_global).with("my-licence-key")
        run { subject.setup }
      end

      it "prints a global confirmation message" do
        expect(run { subject.setup }[:out]).to include("globally")
      end
    end

    context "inside a project (.kamal/ present)" do
      before do
        allow(prompt).to receive(:mask).and_return("my-licence-key")
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with(a_string_ending_with("/.kamal")).and_return(true)
      end

      context "user chooses project scope" do
        before do
          allow(prompt).to receive(:select).and_return("For this project only")
          allow(OctoberCMS::Services::AuthStore).to receive(:store_project)
        end

        it "calls store_project with the entered key" do
          expect(OctoberCMS::Services::AuthStore).to receive(:store_project).with("my-licence-key")
          run { subject.setup }
        end

        it "prints a project confirmation mentioning .kamal/secrets" do
          expect(run { subject.setup }[:out]).to include(".kamal/secrets")
        end
      end

      context "user chooses global scope" do
        before do
          allow(prompt).to receive(:select).and_return("Globally (default for all projects)")
          allow(OctoberCMS::Services::AuthStore).to receive(:store_global)
        end

        it "calls store_global with the entered key" do
          expect(OctoberCMS::Services::AuthStore).to receive(:store_global).with("my-licence-key")
          run { subject.setup }
        end
      end
    end

    context "validation fails" do
      before do
        allow(prompt).to receive(:mask).and_return("bad-key")
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with(a_string_ending_with("/.kamal")).and_return(false)
        allow(subject).to receive(:validate_key).and_return(false)
      end

      it "exits 1" do
        expect(run { subject.setup }[:code]).to eq(1)
      end

      it "does not store the key" do
        expect(OctoberCMS::Services::AuthStore).not_to receive(:store_global)
        expect(OctoberCMS::Services::AuthStore).not_to receive(:store_project)
        run { subject.setup }
      end
    end

    it "strips leading/trailing whitespace from the entered key" do
      allow(prompt).to receive(:mask).and_return("  my-key  ")
      allow(Dir).to receive(:exist?).and_call_original
      allow(Dir).to receive(:exist?).with(a_string_ending_with("/.kamal")).and_return(false)
      expect(OctoberCMS::Services::AuthStore).to receive(:store_global).with("my-key")
      run { subject.setup }
    end
  end

  # ── auth remove ─────────────────────────────────────────────────────────────

  describe "#remove" do
    subject { described_class.new([], {}) }

    context "no key is configured" do
      before { allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return(nil) }

      it "prints 'No licence key configured' to stderr" do
        expect(run { subject.remove }[:err]).to include("No licence key configured")
      end

      it "does not attempt any removal" do
        expect(OctoberCMS::Services::AuthStore).not_to receive(:remove_global)
        expect(OctoberCMS::Services::AuthStore).not_to receive(:remove_project)
        run { subject.remove }
      end
    end

    context "project key is active" do
      before do
        allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return({ key: "k", source: :project })
        allow(prompt).to receive(:yes?).and_return(true)
        allow(OctoberCMS::Services::AuthStore).to receive(:remove_project)
      end

      it "calls remove_project" do
        expect(OctoberCMS::Services::AuthStore).to receive(:remove_project)
        run { subject.remove }
      end

      it "prints a confirmation message" do
        expect(run { subject.remove }[:out]).to include("Licence key removed.")
      end
    end

    context "global key is active" do
      before do
        allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return({ key: "k", source: :global })
        allow(prompt).to receive(:yes?).and_return(true)
        allow(OctoberCMS::Services::AuthStore).to receive(:remove_global)
      end

      it "calls remove_global" do
        expect(OctoberCMS::Services::AuthStore).to receive(:remove_global)
        run { subject.remove }
      end
    end

    context "env var is the active source" do
      before do
        allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return({ key: "k", source: :env })
      end

      it "prints a warning that the env var cannot be removed" do
        result = run { subject.remove }
        expect(result[:err]).to include("OCTOBER_LICENCE_KEY environment variable")
      end

      it "does not attempt any removal" do
        expect(OctoberCMS::Services::AuthStore).not_to receive(:remove_global)
        expect(OctoberCMS::Services::AuthStore).not_to receive(:remove_project)
        run { subject.remove }
      end

      it "does not prompt for confirmation" do
        expect(prompt).not_to receive(:yes?)
        run { subject.remove }
      end
    end

    context "--global flag" do
      let(:instance) { described_class.new([], { "global" => true }) }

      before do
        allow(prompt).to receive(:yes?).and_return(true)
        allow(OctoberCMS::Services::AuthStore).to receive(:remove_global)
      end

      it "targets global store without calling resolve" do
        expect(OctoberCMS::Services::AuthStore).not_to receive(:resolve)
        run { instance.remove }
      end

      it "calls remove_global" do
        expect(OctoberCMS::Services::AuthStore).to receive(:remove_global)
        run { instance.remove }
      end
    end

    context "user declines confirmation" do
      before do
        allow(OctoberCMS::Services::AuthStore).to receive(:resolve).and_return({ key: "k", source: :global })
        allow(prompt).to receive(:yes?).and_return(false)
      end

      it "does not remove anything" do
        expect(OctoberCMS::Services::AuthStore).not_to receive(:remove_global)
        expect(OctoberCMS::Services::AuthStore).not_to receive(:remove_project)
        run { subject.remove }
      end

      it "does not print 'Licence key removed.'" do
        expect(run { subject.remove }[:out]).not_to include("Licence key removed.")
      end
    end
  end

  # ── validate_key (private) ──────────────────────────────────────────────────

  describe "#validate_key" do
    subject { described_class.new([], {}) }

    let(:http)     { instance_double(Net::HTTP) }
    let(:response) { instance_double(Net::HTTPResponse) }

    before do
      allow(Net::HTTP).to receive(:start).and_yield(http)
      allow(http).to receive(:request).and_return(response)
    end

    context "gateway returns 200" do
      before { allow(response).to receive(:code).and_return("200") }

      it "returns true" do
        expect(run { subject.send(:validate_key, "valid-key") }[:return_val]).to be true
      end
    end

    context "gateway returns 401 (invalid key)" do
      before { allow(response).to receive(:code).and_return("401") }

      it "returns false" do
        expect(run { subject.send(:validate_key, "bad-key") }[:return_val]).to be false
      end

      it "prints a rejection message to stderr" do
        result = run { subject.send(:validate_key, "bad-key") }
        expect(result[:err]).to include("rejected by gateway.octobercms.com")
      end

      it "does not print the key in the error message" do
        result = run { subject.send(:validate_key, "super-secret-key") }
        expect(result[:err]).not_to include("super-secret-key")
      end
    end

    context "gateway returns a non-200/401 response (e.g. 503)" do
      before { allow(response).to receive(:code).and_return("503") }

      it "returns false" do
        expect(run { subject.send(:validate_key, "some-key") }[:return_val]).to be false
      end

      it "prints an unexpected-response message to stderr" do
        result = run { subject.send(:validate_key, "some-key") }
        expect(result[:err]).to include("unexpected response 503")
      end
    end

    context "DNS / connection error" do
      before { allow(Net::HTTP).to receive(:start).and_raise(SocketError, "getaddrinfo failed") }

      it "returns false" do
        expect(run { subject.send(:validate_key, "any-key") }[:return_val]).to be false
      end

      it "prints a connectivity message to stderr" do
        result = run { subject.send(:validate_key, "any-key") }
        expect(result[:err]).to include("could not reach gateway.octobercms.com")
      end
    end

    context "connection timeout" do
      before { allow(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout) }

      it "returns false" do
        expect(run { subject.send(:validate_key, "any-key") }[:return_val]).to be false
      end

      it "prints a connectivity message to stderr" do
        result = run { subject.send(:validate_key, "any-key") }
        expect(result[:err]).to include("could not reach gateway.octobercms.com")
      end
    end

    context "read timeout" do
      before { allow(Net::HTTP).to receive(:start).and_raise(Net::ReadTimeout) }

      it "returns false" do
        expect(run { subject.send(:validate_key, "any-key") }[:return_val]).to be false
      end
    end

    context "unexpected error whose message contains the key" do
      before { allow(Net::HTTP).to receive(:start).and_raise(RuntimeError, "failed with key-abc123 here") }

      it "redacts the key from stderr" do
        result = run { subject.send(:validate_key, "key-abc123") }
        expect(result[:err]).not_to include("key-abc123")
        expect(result[:err]).to include("[REDACTED]")
      end
    end

    it "sends HTTP Basic auth with the key as password" do
      allow(response).to receive(:code).and_return("200")
      expect(http).to receive(:request) do |req|
        expect(req["Authorization"]).to include(Base64.strict_encode64("octobercms:my-key").delete("\n"))
        response
      end
      subject.send(:validate_key, "my-key")
    end
  end

  # ── redact (private helper) ──────────────────────────────────────────────────

  describe "#redact" do
    subject { described_class.new([], {}) }

    it "replaces the key with [REDACTED]" do
      result = subject.send(:redact, "Error: invalid key abc123 rejected", "abc123")
      expect(result).to eq("Error: invalid key [REDACTED] rejected")
    end

    it "replaces all occurrences of the key" do
      result = subject.send(:redact, "key=abc123, retry with abc123", "abc123")
      expect(result).to eq("key=[REDACTED], retry with [REDACTED]")
    end

    it "returns text unchanged when key is nil" do
      expect(subject.send(:redact, "some output", nil)).to eq("some output")
    end

    it "returns text unchanged when key is empty" do
      expect(subject.send(:redact, "some output", "")).to eq("some output")
    end
  end
end
