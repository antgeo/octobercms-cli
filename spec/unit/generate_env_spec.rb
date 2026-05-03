RSpec.describe "generate-env.sh", :integration do
  # Runs the script inside a one-shot container (--entrypoint sh).
  # The with-contenv shebang is bypassed by calling sh explicitly.
  # Each example gets a fresh container so there is no .env pre-existing.

  SCRIPT = "sh /etc/s6-overlay/scripts/generate-env.sh"

  # Run the script and return the generated .env content.
  # The script's own log lines are redirected to /dev/null so only .env is returned.
  def env_file(env: DockerHelpers::BASE_ENV)
    out, _, _ = docker_run_sh(
      "#{SCRIPT} >/dev/null 2>&1 && cat /app/.env",
      env: env
    )
    out
  end

  # ── Happy path ──────────────────────────────────────────────────────────────

  context "with all required variables set" do
    it "exits 0" do
      _, _, code = docker_run_sh(SCRIPT, env: DockerHelpers::BASE_ENV)
      expect(code).to eq(0)
    end

    it "writes APP_KEY verbatim" do
      expect(env_file).to include("APP_KEY=#{DockerHelpers::BASE_ENV["APP_KEY"]}")
    end

    it "writes APP_URL" do
      expect(env_file).to include("APP_URL=http://localhost")
    end

    it "writes all DB_ variables" do
      content = env_file
      expect(content).to include("DB_CONNECTION=mysql")
      expect(content).to include("DB_HOST=127.0.0.1")
      expect(content).to include("DB_PORT=3306")
      expect(content).to include("DB_DATABASE=october")
      expect(content).to include("DB_USERNAME=october")
      expect(content).to include("DB_PASSWORD=secret")
    end

    it "defaults APP_ENV to production" do
      expect(env_file).to include("APP_ENV=production")
    end

    it "defaults APP_DEBUG to false" do
      expect(env_file).to include("APP_DEBUG=false")
    end

    it "defaults FILESYSTEM_DISK to local when STORAGE_DRIVER is unset" do
      expect(env_file).to include("FILESYSTEM_DISK=local")
    end

    it "defaults LOG_CHANNEL to stderr" do
      expect(env_file).to include("LOG_CHANNEL=stderr")
    end
  end

  # ── STORAGE_DRIVER mapping ──────────────────────────────────────────────────

  context "STORAGE_DRIVER mapping" do
    it "maps STORAGE_DRIVER=s3 to FILESYSTEM_DISK=s3" do
      content = env_file(env: DockerHelpers::BASE_ENV.merge("STORAGE_DRIVER" => "s3"))
      expect(content).to include("FILESYSTEM_DISK=s3")
    end

    it "maps STORAGE_DRIVER=r2 to FILESYSTEM_DISK=r2" do
      content = env_file(env: DockerHelpers::BASE_ENV.merge("STORAGE_DRIVER" => "r2"))
      expect(content).to include("FILESYSTEM_DISK=r2")
    end

    it "does not expose STORAGE_DRIVER as a key in .env" do
      content = env_file(env: DockerHelpers::BASE_ENV.merge("STORAGE_DRIVER" => "s3"))
      expect(content).not_to include("STORAGE_DRIVER=")
    end
  end

  # ── Idempotency ─────────────────────────────────────────────────────────────

  context "when /app/.env already exists" do
    it "exits 0 without clobbering the existing file" do
      out, _, code = docker_run_sh(
        "echo 'EXISTING=1' > /app/.env && #{SCRIPT} && cat /app/.env",
        env: DockerHelpers::BASE_ENV
      )
      expect(code).to eq(0)
      expect(out).to include("EXISTING=1")
      expect(out).to include("already present, skipping")
      expect(out).not_to include("APP_KEY=")
    end
  end

  # ── OCTOBER_LICENCE_KEY / auth.json generation ──────────────────────────────

  # project:set is an artisan command that lives in the user's OctoberCMS project,
  # not in this runtime image. Tests use a stub artisan that writes a minimal
  # auth.json so we can verify the generate-env logic without a real install.
  STUB_ARTISAN = "echo '<?php file_put_contents(\"/app/auth.json\",\"{}\");' > /app/artisan && chmod +x /app/artisan"

  context "OCTOBER_LICENCE_KEY is set" do
    let(:env_with_key) { DockerHelpers::BASE_ENV.merge("OCTOBER_LICENCE_KEY" => "test-licence-key") }

    it "runs project:set and writes auth.json" do
      out, _, code = docker_run_sh(
        "#{STUB_ARTISAN} && #{SCRIPT} && test -f /app/auth.json && echo AUTH_EXISTS",
        env: env_with_key
      )
      expect(code).to eq(0)
      expect(out).to include("AUTH_EXISTS")
      expect(out).to include("auth.json written")
    end

    it "sets auth.json owned by www-data" do
      out, _, _ = docker_run_sh(
        "#{STUB_ARTISAN} && #{SCRIPT} >/dev/null 2>&1 && stat -c '%U' /app/auth.json",
        env: env_with_key
      )
      expect(out.strip).to eq("www-data")
    end

    it "does not overwrite auth.json if it already exists" do
      out, _, code = docker_run_sh(
        "#{STUB_ARTISAN} && echo '{\"existing\":true}' > /app/auth.json && #{SCRIPT} && cat /app/auth.json",
        env: env_with_key
      )
      expect(code).to eq(0)
      expect(out).to include('"existing":true')
      expect(out).not_to include("auth.json written")
    end
  end

  context "OCTOBER_LICENCE_KEY is not set" do
    it "does not create auth.json" do
      out, _, _ = docker_run_sh(
        "#{SCRIPT} >/dev/null 2>&1; test -f /app/auth.json && echo EXISTS || echo ABSENT",
        env: DockerHelpers::BASE_ENV
      )
      expect(out.strip).to eq("ABSENT")
    end
  end

  # ── Missing required variables ──────────────────────────────────────────────

  %w[APP_KEY APP_URL DB_CONNECTION DB_HOST DB_DATABASE DB_USERNAME DB_PASSWORD].each do |var|
    context "when #{var} is missing" do
      let(:env_without) { DockerHelpers::BASE_ENV.reject { |k, _| k == var } }

      it "exits 1" do
        _, _, code = docker_run_sh(SCRIPT, env: env_without)
        expect(code).to eq(1)
      end

      it "names #{var} in the error message" do
        _, err, _ = docker_run_sh(SCRIPT, env: env_without)
        expect(err).to include(var)
      end

      it "does not create /app/.env" do
        docker_run_sh(SCRIPT, env: env_without)
        out, _, _ = docker_run_sh(
          "#{SCRIPT} 2>/dev/null; test -f /app/.env && echo EXISTS || echo ABSENT",
          env: env_without
        )
        expect(out).to include("ABSENT")
      end
    end
  end
end
