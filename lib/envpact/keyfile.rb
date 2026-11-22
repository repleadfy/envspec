require "json"
require "openssl"

class EnvPact
  # Token files ~/.ob_read and ~/.ob_write: the token is encrypted with
  # AES-256-GCM under a key derived from a passphrase (PBKDF2-HMAC-SHA256).
  # addr, role and expire_time stay readable (for `status`) but, together with
  # the file kind, are bound to the ciphertext as GCM additional data, so
  # editing them breaks decryption.
  module Keyfile
    VERSION        = 1
    KDF            = "pbkdf2-sha256".freeze
    ITERATIONS     = 600_000
    MAX_ITERATIONS = 10_000_000
    KINDS          = %i[read write].freeze

    def self.path(kind)
      File.join(Dir.home, basename(kind))
    end

    def self.write(kind, token:, addr:, role:, expire_time:, passphrase:, iterations: ITERATIONS)
      raise Error, "empty passphrase" if passphrase.nil? || passphrase.empty?
      salt   = OpenSSL::Random.random_bytes(16)
      cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      iv     = cipher.random_iv
      cipher.key = derive(passphrase, salt, iterations)
      cipher.iv = iv
      cipher.auth_data = aad(kind, addr, role, expire_time)
      ct  = cipher.update(token.dup.force_encoding(Encoding::BINARY)) + cipher.final
      tag = cipher.auth_tag

      doc = {
        "v" => VERSION, "kdf" => KDF, "iter" => iterations,
        "salt" => b64(salt), "iv" => b64(iv), "tag" => b64(tag), "ct" => b64(ct),
        "addr" => addr, "role" => role, "expire_time" => expire_time,
        "created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
      AtomicFile.write(path(kind), JSON.pretty_generate(doc) + "\n")
      nil
    end

    # Readable without the passphrase; nil when absent or unparseable.
    def self.meta(kind)
      doc = load_doc(kind)
      return nil unless doc.is_a?(Hash)
      { addr: doc["addr"], role: doc["role"], expire_time: doc["expire_time"] }
    rescue Errno::ENOENT, JSON::ParserError, SystemCallError
      nil
    end

    def self.read(kind, passphrase:)
      file = path(kind)
      name = "~/#{basename(kind)}"
      raise Error, "no #{name}; run envpact login --#{kind}" unless File.exist?(file)
      st = File.stat(file)
      raise Error, "#{name} is readable by others; chmod 600 #{name}" if (st.mode & 0o077) != 0

      corrupted = Error.new("wrong passphrase or corrupted #{name}")
      doc = begin
        JSON.parse(File.read(file))
      rescue JSON::ParserError
        raise corrupted
      end
      raise corrupted unless doc.is_a?(Hash) && doc["v"] == VERSION && doc["kdf"] == KDF
      iter = doc["iter"]
      raise corrupted unless iter.is_a?(Integer) && iter.between?(1, MAX_ITERATIONS)

      begin
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = derive(passphrase, unb64(doc["salt"]), iter)
        cipher.iv = unb64(doc["iv"])
        cipher.auth_tag = unb64(doc["tag"])
        cipher.auth_data = aad(kind, doc["addr"], doc["role"], doc["expire_time"])
        token = cipher.update(unb64(doc["ct"])) + cipher.final
      rescue OpenSSL::Cipher::CipherError, ArgumentError, TypeError, NoMethodError
        raise corrupted
      end
      { token: token.force_encoding(Encoding::UTF_8), addr: doc["addr"], role: doc["role"], expire_time: doc["expire_time"] }
    end

    def self.basename(kind)
      raise ArgumentError, "unknown key file kind: #{kind.inspect}" unless KINDS.include?(kind)
      kind == :read ? ".ob_read" : ".ob_write"
    end

    def self.load_doc(kind)
      JSON.parse(File.read(path(kind)))
    end

    def self.derive(passphrase, salt, iterations)
      OpenSSL::KDF.pbkdf2_hmac(passphrase, salt: salt, iterations: iterations, length: 32, hash: "sha256")
    end

    def self.aad(kind, addr, role, expire_time)
      JSON.generate(["envpact-keyfile", VERSION, kind.to_s, addr, role, expire_time])
    end

    def self.b64(bytes)
      [bytes].pack("m0")
    end

    def self.unb64(text)
      raise ArgumentError, "not a string" unless text.is_a?(String)
      text.unpack("m0").first
    end

    private_class_method :basename, :load_doc, :derive, :aad, :b64, :unb64
  end
end
