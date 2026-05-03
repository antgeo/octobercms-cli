module DockerHelpers
  # Infrastructure image (base target) — no OctoberCMS, buildable without credentials.
  # Build: docker build --target base -f docker/Dockerfile -t octobercms:base .
  INFRA_IMAGE = ENV.fetch("OCTOBERCMS_INFRA_IMAGE", "octobercms:base")

  # Full production image — OctoberCMS installed, requires gateway credentials.
  # Build: DOCKER_BUILDKIT=1 docker build \
  #          --secret id=composer_auth,src=~/.composer/auth.json \
  #          -f docker/Dockerfile -t octobercms:latest .
  IMAGE = ENV.fetch("OCTOBERCMS_IMAGE", "octobercms:latest")

  # Env vars that satisfy all required-variable checks in generate-env.sh.
  BASE_ENV = {
    "APP_KEY"       => "base64:dGVzdGtleXRlc3RrZXl0ZXN0a2V5dGVzdA==",
    "APP_URL"       => "http://localhost",
    "DB_CONNECTION" => "mysql",
    "DB_HOST"       => "127.0.0.1",
    "DB_DATABASE"   => "october",
    "DB_USERNAME"   => "october",
    "DB_PASSWORD"   => "secret",
  }.freeze

  def self.image_missing?(tag = INFRA_IMAGE)
    _, _, status = Open3.capture3("docker", "image", "inspect", tag)
    !status.success?
  end

  def self.full_image_missing?
    image_missing?(IMAGE)
  end

  # ── Low-level helpers ──────────────────────────────────────────────────────

  # Run a one-shot container with a custom entrypoint and command.
  # Returns [stdout, stderr, exit_code].
  def docker_run_sh(command, env: {}, image: INFRA_IMAGE)
    stdout, stderr, status = Open3.capture3(
      "docker", "run", "--rm", "--entrypoint", "sh",
      *env_flags(env), image,
      "-c", command
    )
    [stdout.chomp, stderr.chomp, status.exitstatus]
  end

  # Start a detached container. Returns the container ID.
  def docker_run_d(env: {}, ports: {}, network: nil, name: nil, image: INFRA_IMAGE)
    args = ["docker", "run", "-d"]
    args += ["--name", name] if name
    args += ["--network", network] if network
    args += ports.map { |host, container| ["-p", "#{host}:#{container}"] }.flatten
    args += env_flags(env)
    args << image
    stdout, stderr, status = Open3.capture3(*args)
    raise "docker run failed: #{stderr}" unless status.success?
    stdout.chomp
  end

  # Exec a command in a running container. Returns [stdout, stderr, exit_code].
  def docker_exec(container_id, *cmd)
    stdout, stderr, status = Open3.capture3(
      "docker", "exec", container_id, *cmd
    )
    [stdout.chomp, stderr.chomp, status.exitstatus]
  end

  def docker_stop(*container_ids)
    container_ids.compact.each do |id|
      system("docker", "rm", "-f", id, out: File::NULL, err: File::NULL)
    end
  end

  def docker_network_create(name)
    system("docker", "network", "create", name, out: File::NULL, err: File::NULL)
    name
  end

  def docker_network_rm(name)
    system("docker", "network", "rm", name, out: File::NULL, err: File::NULL)
  end

  # ── HTTP helpers ───────────────────────────────────────────────────────────

  def http_get(host, port, path)
    uri = URI::HTTP.build(host: host, port: port, path: path)
    Net::HTTP.get_response(uri)
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET
    nil
  end

  # Retry a block until it returns truthy or timeout is reached.
  def wait_for(timeout: 30, interval: 0.5)
    deadline = Time.now + timeout
    loop do
      result = yield
      return result if result
      raise "timed out after #{timeout}s" if Time.now > deadline
      sleep interval
    end
  end

  # Wait until GET path on host:port returns any HTTP response.
  def wait_for_http(host, port, path: "/up", timeout: 60)
    wait_for(timeout: timeout) { http_get(host, port, path) }
  end

  # Find an available TCP port on localhost.
  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  private

  def env_flags(env)
    env.flat_map { |k, v| ["-e", "#{k}=#{v}"] }
  end
end
