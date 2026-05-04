class EnvSpec
  # Best-effort, conservative inference of envspec syntax from a key name and
  # observed usage data. Output is ALWAYS suggestive — the generated env.spec
  # file marks heuristic decisions as TODO comments so the dev reviews them.
  module Heuristics
    SECRET_NAME_RE = /(?:KEY|SECRET|TOKEN|PASSWORD|PASS|CREDENTIAL|PRIVATE)\b/.freeze
    DSN_NAME_RE    = /(?:_URL|_URI|_DSN|DATABASE_URL|REDIS_URL|MONGO_URL|AMQP_URL)\z/.freeze
    INT_NAME_RE    = /(?:PORT|TIMEOUT|INTERVAL|SIZE|COUNT|LIMIT|MAX_|MIN_)/.freeze
    BOOL_NAME_RE   = /\A(?:DEBUG|VERBOSE|ENABLE_|.*_ENABLED|IS_|HAS_|USE_)/.freeze

    def self.infer(name, usages)
      {
        secret:   secret?(name),
        type:     infer_type(name),
        optional: usages.any? { |u| u[:optional] },
        default:  pick_default(usages),
      }
    end

    def self.secret?(name)
      return true if name =~ SECRET_NAME_RE
      return true if name =~ DSN_NAME_RE
      false
    end

    def self.infer_type(name)
      return :dsn  if name =~ DSN_NAME_RE
      return :int  if name =~ INT_NAME_RE
      return :bool if name =~ BOOL_NAME_RE
      :str
    end

    def self.pick_default(usages)
      defaults = usages.map { |u| u[:default] }.compact.uniq
      defaults.first
    end
  end
end
