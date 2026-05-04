require "tmpdir"
require_relative "../../../lib/octobercms/services/kamal"

RSpec.describe OctoberCMS::Services::Kamal do
  let(:tmpdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(tmpdir) }

  let(:mock_cmd) { instance_double(TTY::Command) }
  subject(:kamal) do
    described_class.new(project_dir: tmpdir, licence_key: "secret-key-123", cmd: mock_cmd)
  end

  describe "#run" do
    context "when the command succeeds" do
      before do
        allow(mock_cmd).to receive(:run)
          .with("kamal", "build", "push", chdir: tmpdir)
          .and_return(["build output", ""])
      end

      it "returns [stdout, stderr]" do
        expect(kamal.run("build", "push")).to eq(["build output", ""])
      end
    end

    context "when the command fails" do
      let(:exit_result) do
        double("result", exit_status: 1, out: "", err: "error: secret-key-123 exposed")
      end

      before do
        allow(mock_cmd).to receive(:run)
          .and_raise(TTY::Command::ExitError.new("kamal", exit_result))
      end

      it "raises Kamal::Error" do
        expect { kamal.run("build", "push") }
          .to raise_error(OctoberCMS::Services::Kamal::Error)
      end

      it "redacts the licence key from the error message" do
        expect { kamal.run("build", "push") }
          .to raise_error(OctoberCMS::Services::Kamal::Error) do |e|
            expect(e.message).not_to include("secret-key-123")
            expect(e.message).to include("[REDACTED]")
          end
      end
    end
  end

  describe "#run!" do
    context "when the command succeeds" do
      before do
        allow(mock_cmd).to receive(:run).and_return(["ok", ""])
      end

      it "returns [stdout, stderr]" do
        expect(kamal.run!("deploy")).to eq(["ok", ""])
      end

      it "does not raise" do
        expect { kamal.run!("deploy") }.not_to raise_error
      end
    end

    context "when the command fails" do
      let(:exit_result) { double("result", exit_status: 1, out: "", err: "deploy failed") }

      before do
        allow(mock_cmd).to receive(:run)
          .and_raise(TTY::Command::ExitError.new("kamal deploy", exit_result))
      end

      it "raises Thor::Error (not Kamal::Error)" do
        expect { kamal.run!("deploy") }.to raise_error(Thor::Error)
      end
    end
  end

  describe "without a licence key" do
    subject(:kamal) { described_class.new(project_dir: tmpdir, cmd: mock_cmd) }

    before do
      allow(mock_cmd).to receive(:run).and_return(["clean output", ""])
    end

    it "returns output unchanged" do
      out, = kamal.run("config")
      expect(out).to eq("clean output")
    end
  end
end
