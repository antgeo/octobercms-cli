RSpec.describe "running container", :integration do
  # ── Nginx routing (:integration, uses INFRA_IMAGE) ───────────────────────────
  #
  # Uses the infrastructure image (no OctoberCMS). Nginx routing rules —
  # deny directives, PHP pass-through — work regardless of whether the PHP
  # application is installed. The container is shared for all routing examples.

  describe "Nginx routing" do
    before(:context) do
      @port = free_port
      @container = docker_run_d(
        env:   DockerHelpers::BASE_ENV,
        ports: { @port => 80 },
        image: DockerHelpers::INFRA_IMAGE
      )
      # Wait until Nginx is up — /up may 404 or 503, any response is sufficient.
      wait_for_http("127.0.0.1", @port, timeout: 30)
    end

    after(:context) do
      docker_stop(@container)
    end

    # ── Sensitive path denial ─────────────────────────────────────────────────

    {
      "/.env"          => 403,
      "/artisan"       => 403,
      "/composer.json" => 403,
      "/composer.lock" => 403,
      "/.htaccess"     => 403,
    }.each do |path, expected_status|
      it "returns #{expected_status} for #{path}" do
        response = http_get("127.0.0.1", @port, path)
        expect(response.code.to_i).to eq(expected_status),
          "GET #{path} expected #{expected_status}, got #{response.code}"
      end
    end
  end

  # ── /up health check states (:full, uses IMAGE) ───────────────────────────────
  #
  # Requires the production image (OctoberCMS installed) and a MySQL 8.0 container.
  # Tests the three states the /up endpoint transitions through:
  #
  #   State 1: DB connected, migrations not run → 503, migrations_table: missing
  #   State 2: After october:migrate            → 200, status: ok
  #
  # The MySQL container and Docker network are torn down after the context.

  describe "/up health check states", :full do
    MYSQL_DATABASE = "october"
    MYSQL_USER     = "october"
    MYSQL_PASSWORD = "secret"
    MYSQL_ROOT_PW  = "rootsecret"

    before(:context) do
      @network    = docker_network_create("octobercms-test-#{SecureRandom.hex(4)}")
      @mysql_name = "test-mysql-#{SecureRandom.hex(4)}"
      @port       = free_port

      # Start MySQL 8.0 on the isolated test network.
      Open3.capture3(
        "docker", "run", "-d",
        "--name",    @mysql_name,
        "--network", @network,
        "-e", "MYSQL_ROOT_PASSWORD=#{MYSQL_ROOT_PW}",
        "-e", "MYSQL_DATABASE=#{MYSQL_DATABASE}",
        "-e", "MYSQL_USER=#{MYSQL_USER}",
        "-e", "MYSQL_PASSWORD=#{MYSQL_PASSWORD}",
        "mysql:8.0",
        "--default-authentication-plugin=mysql_native_password"
      )

      # Wait for MySQL to accept connections (up to 60s).
      wait_for(timeout: 60) do
        _, _, status = Open3.capture3(
          "docker", "exec", @mysql_name,
          "mysqladmin", "ping", "-u", "root", "-p#{MYSQL_ROOT_PW}", "--silent"
        )
        status.success?
      end

      # Start the app container on the same network, pointed at MySQL.
      app_env = DockerHelpers::BASE_ENV.merge(
        "DB_HOST"     => @mysql_name,
        "DB_DATABASE" => MYSQL_DATABASE,
        "DB_USERNAME" => MYSQL_USER,
        "DB_PASSWORD" => MYSQL_PASSWORD,
      )
      @container = docker_run_d(
        env:     app_env,
        ports:   { @port => 80 },
        network: @network,
        image:   DockerHelpers::IMAGE
      )

      wait_for_http("127.0.0.1", @port, timeout: 60)
    end

    after(:context) do
      docker_stop(@container, @mysql_name)
      docker_network_rm(@network)
    end

    context "before migrations have been run" do
      it "GET /up returns 503" do
        response = http_get("127.0.0.1", @port, "/up")
        expect(response.code.to_i).to eq(503)
      end

      it "GET /up reports status: error" do
        body = JSON.parse(http_get("127.0.0.1", @port, "/up").body)
        expect(body["status"]).to eq("error")
      end

      it "GET /up reports database: ok (DB is reachable)" do
        body = JSON.parse(http_get("127.0.0.1", @port, "/up").body)
        expect(body.dig("checks", "database")).to eq("ok")
      end

      it "GET /up reports migrations_table: missing" do
        body = JSON.parse(http_get("127.0.0.1", @port, "/up").body)
        expect(body.dig("checks", "migrations_table")).to eq("missing")
      end

      it "GET /up returns JSON with a checks key" do
        response = http_get("127.0.0.1", @port, "/up")
        expect { JSON.parse(response.body) }.not_to raise_error
        expect(JSON.parse(response.body)).to have_key("checks")
      end
    end

    context "after october:migrate has been run" do
      before(:context) do
        _, err, code = docker_exec(
          @container, "php", "artisan", "october:migrate", "--force"
        )
        raise "october:migrate failed (exit #{code}): #{err}" unless code.zero?
      end

      it "GET /up returns 200" do
        response = http_get("127.0.0.1", @port, "/up")
        expect(response.code.to_i).to eq(200),
          "/up expected 200, got #{response.code}. Body: #{response.body}"
      end

      it "GET /up reports status: ok" do
        body = JSON.parse(http_get("127.0.0.1", @port, "/up").body)
        expect(body["status"]).to eq("ok")
      end

      it "GET /up reports all checks as ok" do
        body = JSON.parse(http_get("127.0.0.1", @port, "/up").body)
        body["checks"].each do |name, result|
          expect(result).to eq("ok"), "check '#{name}' expected 'ok', got '#{result}'"
        end
      end
    end
  end
end
