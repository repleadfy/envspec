require "socket"
require "json"
require "time"
require "tmpdir"
require "fileutils"

class EnvPact
  # A small local agent that holds the READ token in memory for a window, so
  # `pull`/`run` need no passphrase while it is unlocked. Never used for the
  # write token.
  #
  # Protocol: one JSON line per connection on a Unix socket (0600, in a 0700
  # directory). Ops: token, status (no token), lock.
  module Agent
    MAX_LIFETIME = 8 * 3600
    IO_TIMEOUT   = 2

    # --- paths ------------------------------------------------------------

    # $ENVPACT_AGENT_SOCK, or <runtime dir>/envpact-<uid>/agent.sock. The
    # default directory is created 0700; one that exists with another owner,
    # a looser mode, or as a symlink is an error.
    def self.socket_path
      if (explicit = ENV["ENVPACT_AGENT_SOCK"]) && !explicit.empty?
        return explicit
      end
      dir = File.join(ENV["XDG_RUNTIME_DIR"] || Dir.tmpdir, "envpact-#{Process.uid}")
      ensure_private_dir(dir)
      File.join(dir, "agent.sock")
    end

    def self.ensure_private_dir(dir)
      Dir.mkdir(dir, 0o700) unless File.exist?(dir) || File.symlink?(dir)
      st = File.lstat(dir)
      unless st.directory? && st.uid == Process.uid && (st.mode & 0o077).zero?
        raise Error, "#{dir} must be a directory owned by you with mode 0700 (remove it or fix it)"
      end
    end

    # --- peer checks ------------------------------------------------------

    def self.uid_allowed?(uid)
      uid == Process.uid
    end

    # Refuses a connection from another uid. When the OS gives no way to ask,
    # the 0600 socket in a 0700 directory is the guard.
    def self.peer_allowed?(sock)
      uid = peer_uid(sock)
      uid.nil? || uid_allowed?(uid)
    end

    def self.peer_uid(sock)
      if sock.respond_to?(:getpeereid)
        sock.getpeereid.first
      elsif defined?(Socket::SO_PEERCRED)
        sock.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).data.unpack("iII")[1]
      end
    rescue StandardError
      nil
    end

    def self.cap_until(time)
      [time, Time.now + MAX_LIFETIME].min
    end

    # --- client -----------------------------------------------------------

    # Returns the parsed reply, or nil when there is no agent (no socket, or
    # nobody listening).
    def self.request(op)
      path = socket_path
      return nil unless File.socket?(path)
      sock = UNIXSocket.new(path)
      begin
        sock.write(JSON.generate("op" => op) + "\n")
        return nil unless IO.select([sock], nil, nil, IO_TIMEOUT)
        line = sock.gets
        line && JSON.parse(line)
      ensure
        sock.close
      end
    rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ENOTSOCK, Errno::EACCES, Errno::ECONNRESET,
           Errno::EPIPE, JSON::ParserError
      nil
    end

    # --- server -----------------------------------------------------------

    # Starts the agent in a detached child and returns its pid. A running
    # agent is replaced, a dead socket is cleaned up. The socket is bound
    # here, before the fork, so failures surface in the caller and the socket
    # is ready the moment this returns.
    def self.start(token:, addr:, until_time:)
      path = socket_path
      replace_existing(path)
      until_time = cap_until(until_time)

      server = bind(path)
      ino = File.stat(path).ino
      pid = fork do
        serve(server, path, ino, token, addr, until_time)
      end
      server.close
      Process.detach(pid)
      pid
    end

    def self.replace_existing(path)
      return unless File.exist?(path) || File.symlink?(path)
      raise Error, "#{path} exists and is not an agent socket; not touching it" unless File.lstat(path).socket?
      if request("lock")
        50.times do
          break unless File.exist?(path)
          sleep 0.05
        end
      end
      File.unlink(path) if File.exist?(path)
    end

    def self.bind(path)
      old = File.umask(0o177)
      begin
        server = UNIXServer.new(path)
      rescue ArgumentError, SystemCallError => e
        raise Error, "cannot create agent socket #{path} (#{e.class.name.split('::').last})"
      ensure
        File.umask(old)
      end
      File.chmod(0o600, path)
      server
    end

    # Runs in the forked child. Leaves through exit!, so the parent's at_exit
    # hooks (minitest, for one) never run here.
    def self.serve(server, path, ino, token, addr, until_time)
      Process.setsid
      $0 = "envpact-agent"
      Process.setproctitle("envpact-agent") if Process.respond_to?(:setproctitle)
      $stdin.reopen(File::NULL)
      $stdout.reopen(File::NULL, "w")
      $stderr.reopen(File::NULL, "w")
      stop = false
      %w[TERM INT HUP].each { |sig| trap(sig) { stop = true } }

      until stop
        left = until_time - Time.now
        break if left <= 0
        next unless IO.select([server], nil, nil, [left, 1].min)
        sock = begin
          server.accept
        rescue SystemCallError, IOError
          next
        end
        stop = true if handle(sock, token, addr, until_time)
      end
    rescue StandardError
      nil
    ensure
      begin
        File.unlink(path) if File.socket?(path) && File.stat(path).ino == ino
      rescue SystemCallError
        nil
      end
      exit!(0)
    end

    # Returns true when the agent should stop (lock).
    def self.handle(sock, token, addr, until_time)
      return false unless peer_allowed?(sock)
      return false unless IO.select([sock], nil, nil, IO_TIMEOUT)
      line = sock.gets
      req = begin
        JSON.parse(line.to_s)
      rescue JSON::ParserError
        nil
      end
      op = req.is_a?(Hash) ? req["op"] : nil
      untill = until_time.utc.iso8601
      reply, stop =
        case op
        when "token"  then [{ "token" => token, "addr" => addr, "until" => untill }, false]
        when "status" then [{ "addr" => addr, "until" => untill }, false]
        when "lock"   then [{ "ok" => true }, true]
        else [{ "error" => "unknown op" }, false]
        end
      sock.write(JSON.generate(reply) + "\n")
      stop
    rescue SystemCallError, IOError
      false
    ensure
      sock.close unless sock.closed?
    end

    private_class_method :ensure_private_dir, :peer_uid, :replace_existing, :bind, :serve, :handle
  end
end
