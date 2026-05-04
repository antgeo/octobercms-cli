require "tmpdir"
require "stringio"
require_relative "../../lib/octobercms/commands/deploy"

RSpec.describe OctoberCMS::Commands::Deploy do
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

  let(:mock_kamal) do
    instance_double(OctoberCMS::Services::Kamal).tap do |k|
      allow(k).to receive(:run!).and_return(["", ""])
    end
  end
  let(:mock_doctor) { instance_double(OctoberCMS::Commands::Doctor, call: true) }

  subject(:deploy) do
    described_class.new(project_dir: tmpdir, kamal: mock_kamal, doctor: mock_doctor)
  end

  # ── #call ──────────────────────────────────────────────────────────────────

  describe "#call" do
    it "runs pre-flight checks" do
      run { deploy.call }
      expect(mock_doctor).to have_received(:call)
    end

    it "builds and pushes the image" do
      run { deploy.call }
      expect(mock_kamal).to have_received(:run!).with("build", "push")
    end

    it "runs migrations by default" do
      run { deploy.call }
      expect(mock_kamal).to have_received(:run!)
        .with("app", "exec", "--reuse", "php artisan october:migrate")
    end

    it "runs kamal deploy" do
      run { deploy.call }
      expect(mock_kamal).to have_received(:run!).with("deploy")
    end

    it "runs steps in order: build push → migrate → deploy" do
      order = []
      allow(mock_kamal).to receive(:run!) do |*args|
        order << args.first(2).join(" ")
        ["", ""]
      end
      run { deploy.call }
      expect(order).to eq(["build push", "app exec", "deploy"])
    end

    it "prints a completion message" do
      result = run { deploy.call }
      expect(result[:out]).to include("Deploy complete")
    end

    context "with skip_migrate: true" do
      subject(:deploy) do
        described_class.new(project_dir: tmpdir, kamal: mock_kamal, doctor: mock_doctor,
                            skip_migrate: true)
      end

      it "omits the migration step" do
        run { deploy.call }
        expect(mock_kamal).not_to have_received(:run!)
          .with("app", "exec", "--reuse", "php artisan october:migrate")
      end

      it "still builds and deploys" do
        run { deploy.call }
        expect(mock_kamal).to have_received(:run!).with("build", "push")
        expect(mock_kamal).to have_received(:run!).with("deploy")
      end
    end

    context "when pre-flight checks fail" do
      let(:mock_doctor) { instance_double(OctoberCMS::Commands::Doctor, call: false) }

      it "exits with code 1" do
        result = run { deploy.call }
        expect(result[:code]).to eq(1)
      end

      it "does not run any kamal commands" do
        run { deploy.call }
        expect(mock_kamal).not_to have_received(:run!)
      end
    end
  end

  # ── #build_only ───────────────────────────────────────────────────────────

  describe "#build_only" do
    it "calls kamal build push" do
      run { deploy.build_only }
      expect(mock_kamal).to have_received(:run!).with("build", "push")
    end

    it "does not call deploy" do
      run { deploy.build_only }
      expect(mock_kamal).not_to have_received(:run!).with("deploy")
    end

    it "does not run pre-flight" do
      run { deploy.build_only }
      expect(mock_doctor).not_to have_received(:call)
    end
  end

  # ── #migrate_only ─────────────────────────────────────────────────────────

  describe "#migrate_only" do
    it "calls kamal app exec --reuse with the october:migrate command" do
      run { deploy.migrate_only }
      expect(mock_kamal).to have_received(:run!)
        .with("app", "exec", "--reuse", "php artisan october:migrate")
    end

    it "does not run pre-flight" do
      run { deploy.migrate_only }
      expect(mock_doctor).not_to have_received(:call)
    end
  end

  # ── #console ──────────────────────────────────────────────────────────────

  describe "#console" do
    it "execs kamal app exec --interactive bash (process replacement for real TTY)" do
      expect(deploy).to receive(:exec)
        .with("kamal", "app", "exec", "--interactive", "bash", chdir: tmpdir)
      deploy.console
    end
  end

  # ── #logs ─────────────────────────────────────────────────────────────────

  describe "#logs" do
    it "follows logs with 100 lines by default" do
      run { deploy.logs }
      expect(mock_kamal).to have_received(:run!)
        .with("app", "logs", "--follow", "--lines", "100")
    end

    context "with no_follow: true" do
      subject(:deploy) do
        described_class.new(project_dir: tmpdir, kamal: mock_kamal, doctor: mock_doctor,
                            no_follow: true)
      end

      it "omits the --follow flag" do
        run { deploy.logs }
        expect(mock_kamal).to have_received(:run!)
          .with("app", "logs", "--lines", "100")
      end
    end

    context "with lines: 50" do
      subject(:deploy) do
        described_class.new(project_dir: tmpdir, kamal: mock_kamal, doctor: mock_doctor,
                            lines: 50)
      end

      it "passes the custom line count" do
        run { deploy.logs }
        expect(mock_kamal).to have_received(:run!)
          .with("app", "logs", "--follow", "--lines", "50")
      end
    end
  end
end
