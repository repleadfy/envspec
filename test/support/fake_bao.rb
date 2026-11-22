require "socket"
require "json"
require "uri"

# A tiny in-process HTTP server standing in for OpenBao. Responses are
# configured per [method, path]; every request is recorded.
#
#   bao = FakeBao.new
#   bao.on("GET", "/v1/secret/data/a/b", body: { "data" => { "data" => { "A" => "1" } } })
#   bao.on("POST", "/v1/x") { |req| [200, { "ok" => true }] }
#   bao.on("GET", "/v1/slow", hang: true)
#   bao.requests.last.headers["x-vault-token"]
#   bao.stop
class FakeBao
  Request = Struct.new(:method, :path, :query, :headers, :body)

  attr_reader :requests, :port

  def initialize
    @server    = TCPServer.new("127.0.0.1", 0)
    @port      = @server.addr[1]
    @requests  = []
    @responses = {}
    @lock      = Mutex.new
    @threads   = []
    @stopped   = false
    @acceptor  = Thread.new { accept_loop }
  end

  def addr
    "http://127.0.0.1:#{@port}"
  end

  # status/body are static; a block is called with the Request and returns
  # [status, body_hash].
  def on(method, path, status: 200, body: {}, hang: false, &block)
    @lock.synchronize { @responses[[method, path]] = { status: status, body: body, hang: hang, block: block } }
    self
  end

  def requests_for(method, path = nil)
    @lock.synchronize { @requests.select { |r| r.method == method && (path.nil? || r.path == path) } }
  end

  def stop
    @stopped = true
    @server.close unless @server.closed?
    @acceptor.kill
    @threads.each(&:kill)
  end

  private

  def accept_loop
    until @stopped
      client = @server.accept
      @threads << Thread.new(client) { |c| handle(c) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(sock)
    request_line = sock.gets
    return unless request_line
    method, target, = request_line.split(" ")
    headers = {}
    while (line = sock.gets) && line != "\r\n"
      k, v = line.chomp.split(": ", 2)
      headers[k.downcase] = v
    end
    body = headers["content-length"] ? sock.read(headers["content-length"].to_i) : ""
    uri = URI.parse(target)
    req = Request.new(method, uri.path, uri.query, headers, body)
    resp = @lock.synchronize { @requests << req; @responses[[method, uri.path]] }

    if resp && resp[:hang]
      sleep 30
      return
    end
    status, payload =
      if resp.nil?
        [404, { "errors" => [] }]
      elsif resp[:block]
        resp[:block].call(req)
      else
        [resp[:status], resp[:body]]
      end
    json = JSON.generate(payload)
    sock.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
  rescue IOError, SystemCallError
    nil
  ensure
    sock.close unless sock.closed?
  end
end
