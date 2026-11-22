require "io/console"

class EnvPact
  # Asks the human, on the controlling terminal and nowhere else: never stdin,
  # argv or ENV, so a script or an agent driving envpact cannot answer for the
  # user.
  class Prompt
    NO_TTY = "needs a terminal to confirm writes".freeze

    def initialize(tty_path = "/dev/tty")
      @tty_path = tty_path
    end

    def available?
      File.open(@tty_path, "r+") { |io| io.tty? }
    rescue SystemCallError, IOError
      false
    end

    # Reads a line without echo.
    def secret(label)
      with_tty do |tty|
        tty.write(label)
        tty.flush
        line = tty.noecho(&:gets)
        tty.write("\n")
        line.to_s.chomp.chomp("\r")
      end
    end

    # Only "y" / "yes" (any case) is a yes.
    def confirm(label)
      with_tty do |tty|
        tty.write(label)
        tty.flush
        %w[y yes].include?(tty.gets.to_s.strip.downcase)
      end
    end

    private

    def with_tty
      tty = begin
        File.open(@tty_path, "r+")
      rescue SystemCallError, IOError
        raise Error, NO_TTY
      end
      begin
        raise Error, NO_TTY unless tty.tty?
        yield tty
      ensure
        tty.close
      end
    end
  end
end
