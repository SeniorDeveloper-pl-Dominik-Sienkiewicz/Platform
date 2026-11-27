require "date"
require "psych"

config = ARGV.fetch(0)
exit unless File.exist?(config)

source = File.read(config)
lines = source.lines
today = Time.now.utc.to_date
root = Psych.parse_stream(source).children.first&.root
if root
  abort "#{config}: expected a Grype configuration mapping" unless root.is_a?(Psych::Nodes::Mapping)
  root.children.each_slice(2) do |key, rules|
    next unless key.value == "ignore"
    next if rules.is_a?(Psych::Nodes::Scalar) && rules.plain && rules.value.empty?
    abort "#{config}: expected a list of ignore rules" unless rules.is_a?(Psych::Nodes::Sequence)

    rules.children.each do |rule|
      line = rule.start_line
      annotation = "::error file=.grype.yaml,line=#{line + 1}::Grype exception"
      comment = line.positive? ? lines[line - 1] : ""
      expiry = comment[/^\s*#\s*expires:\s*(\d{4}-\d{2}-\d{2})(?:\s*;|\s*$)/, 1]
      begin
        date = Date.iso8601(expiry.to_s)
      rescue ArgumentError
        abort "#{annotation} needs a valid # expires: YYYY-MM-DD comment directly above it"
      end
      abort "#{annotation} expired on #{expiry}; update the dependency or renew the exception" if date < today
    end
  end
end

File.write(".grype.yaml", source)
