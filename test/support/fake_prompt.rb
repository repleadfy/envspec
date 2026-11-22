# Duck type for EnvPact::Prompt with queued answers. A prompt with no answer
# left fails the test: it means the code asked something it should not.
class FakePrompt
  attr_reader :labels

  def initialize(secrets: [], confirms: [], available: true)
    @secrets = secrets.dup
    @confirms = confirms.dup
    @available = available
    @labels = []
  end

  def available?
    @available
  end

  def secret(label)
    @labels << label
    raise EnvPact::Error, "needs a terminal to confirm writes" unless @available
    raise "unexpected secret prompt: #{label}" if @secrets.empty?
    @secrets.shift
  end

  def confirm(label)
    @labels << label
    raise EnvPact::Error, "needs a terminal to confirm writes" unless @available
    raise "unexpected confirm prompt: #{label}" if @confirms.empty?
    @confirms.shift
  end
end
