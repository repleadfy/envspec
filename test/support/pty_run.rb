require "pty"

# Runs a command with a controlling terminal and answers its prompts.
#
#   out, code = PtyRun.run(["envpact", "login"], env: {...},
#                          answers: [[/Passphrase/, "s3cret"], [/Repeat/, "s3cret"]])
#
# Each answer is sent once its pattern shows up in the output after the
# previous answer. stdout and stderr arrive merged (as on a real terminal).
module PtyRun
  def self.run(cmd, env: {}, answers: [], timeout: 60)
    out = +""
    answers = answers.dup
    pos = 0
    reader, writer, pid = PTY.spawn(env, *cmd)
    deadline = Time.now + timeout
    begin
      loop do
        left = deadline - Time.now
        if left <= 0
          Process.kill("KILL", pid)
          out << "\n[PtyRun: timeout]"
          break
        end
        next unless IO.select([reader], nil, nil, [left, 0.5].min)
        begin
          out << reader.read_nonblock(4096)
        rescue IO::WaitReadable
          next
        rescue EOFError, Errno::EIO
          break
        end
        pat, reply = answers.first
        if pat && out[pos..-1] =~ pat
          pos = out.length
          writer.write(reply + "\n")
          answers.shift
        end
      end
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
    _, status = Process.wait2(pid)
    [out.force_encoding(Encoding::UTF_8), status.exitstatus]
  end
end
