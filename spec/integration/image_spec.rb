RSpec.describe "Docker image structure", :integration do
  # These tests use `docker run --rm` one-shot containers — no MySQL or running
  # app needed. They verify the image was assembled correctly.

  def sh_in_image(command)
    docker_run_sh(command, env: {})
  end

  # ── PHP extensions ───────────────────────────────────────────────────────────

  describe "PHP extensions" do
    let(:modules) do
      out, _, _ = sh_in_image("php -m")
      out.downcase
    end

    %w[pdo_mysql gd opcache bcmath mbstring zip].each do |ext|
      it "has #{ext} loaded" do
        expect(modules).to include(ext)
      end
    end
  end

  # ── Required binaries ────────────────────────────────────────────────────────

  describe "required binaries" do
    %w[nginx php php-fpm curl mysql].each do |bin|
      it "has #{bin} in PATH" do
        _, _, code = sh_in_image("which #{bin}")
        expect(code).to eq(0), "expected #{bin} to be present in the image"
      end
    end
  end

  # ── PHP version ──────────────────────────────────────────────────────────────

  describe "PHP version" do
    it "is 8.3.x" do
      out, _, _ = sh_in_image("php -r 'echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;'")
      expect(out).to eq("8.3")
    end
  end

  # ── s6-overlay service definitions ───────────────────────────────────────────

  describe "s6-overlay service definitions" do
    it "has generate-env run script and it is executable" do
      _, _, code = sh_in_image("test -x /etc/s6-overlay/s6-rc.d/generate-env/up")
      expect(code).to eq(0)
    end

    it "has php-fpm run script and it is executable" do
      _, _, code = sh_in_image("test -x /etc/s6-overlay/s6-rc.d/php-fpm/run")
      expect(code).to eq(0)
    end

    it "has nginx run script and it is executable" do
      _, _, code = sh_in_image("test -x /etc/s6-overlay/s6-rc.d/nginx/run")
      expect(code).to eq(0)
    end

    it "has generate-env.sh and it is executable" do
      _, _, code = sh_in_image("test -x /etc/s6-overlay/scripts/generate-env.sh")
      expect(code).to eq(0)
    end

    it "nginx depends on php-fpm" do
      _, _, code = sh_in_image("test -f /etc/s6-overlay/s6-rc.d/nginx/dependencies.d/php-fpm")
      expect(code).to eq(0)
    end

    it "php-fpm depends on generate-env" do
      _, _, code = sh_in_image("test -f /etc/s6-overlay/s6-rc.d/php-fpm/dependencies.d/generate-env")
      expect(code).to eq(0)
    end
  end

  # ── Volume contract ───────────────────────────────────────────────────────────

  describe "/app/storage" do
    it "exists" do
      _, _, code = sh_in_image("test -d /app/storage")
      expect(code).to eq(0)
    end

    it "is owned by www-data" do
      out, _, _ = sh_in_image("stat -c '%U' /app/storage")
      expect(out).to eq("www-data")
    end

    %w[app framework/cache framework/sessions framework/views logs].each do |subdir|
      it "contains storage/#{subdir}" do
        _, _, code = sh_in_image("test -d /app/storage/#{subdir}")
        expect(code).to eq(0), "expected /app/storage/#{subdir} to exist"
      end
    end
  end

  describe "/app/plugins" do
    it "exists and is owned by www-data" do
      out, _, _ = sh_in_image("stat -c '%U' /app/plugins")
      expect(out).to eq("www-data")
    end
  end

  describe "/app/themes" do
    it "exists and is owned by www-data" do
      out, _, _ = sh_in_image("stat -c '%U' /app/themes")
      expect(out).to eq("www-data")
    end
  end

  describe "/app-skeleton" do
    it "exists and is owned by www-data" do
      out, _, _ = sh_in_image("stat -c '%U' /app-skeleton")
      expect(out).to eq("www-data")
    end
  end

  # ── Secret hygiene ────────────────────────────────────────────────────────────

  describe "secret hygiene" do
    it "does not contain auth.json" do
      _, _, code = sh_in_image("test ! -f /app/auth.json")
      expect(code).to eq(0), "auth.json must not be present in the image"
    end

    it "does not contain .env" do
      _, _, code = sh_in_image("test ! -f /app/.env")
      expect(code).to eq(0), ".env must not be baked into the image"
    end
  end

  # ── Nginx config ──────────────────────────────────────────────────────────────

  describe "nginx configuration" do
    it "config passes nginx -t" do
      # Create a minimal stub .env and php-fpm socket so nginx config test doesn't fail
      # on missing fastcgi upstream — only test config parsing, not connectivity.
      _, _, code = sh_in_image("nginx -t 2>/dev/null; echo $?")
      # nginx -t exits 0 on valid config
      _, _, code = sh_in_image("nginx -t")
      expect(code).to eq(0)
    end
  end

  # ── Image size ────────────────────────────────────────────────────────────────

  describe "image size" do
    it "is under 600 MB uncompressed (CI enforces the 300 MB compressed target)" do
      out, _, _ = Open3.capture3(
        "docker", "image", "inspect", DockerHelpers::INFRA_IMAGE,
        "--format", "{{.Size}}"
      )
      size_mb = out.to_i / (1024 * 1024)
      expect(size_mb).to be < 600,
        "image is #{size_mb} MB uncompressed (target: <600 MB local / <300 MB compressed in CI)"
    end
  end
end
