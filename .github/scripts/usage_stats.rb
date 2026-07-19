# Reports the beta's "number of users" from App Store Connect: total TestFlight
# testers plus a breakdown by invite type, state and beta group, and per-build
# assigned-tester counts. Synchronous - no report generation to wait on.
# Usage: bundle exec ruby .github/scripts/usage_stats.rb [out_dir]
require "fileutils"
require_relative "asc_api"

BUNDLE_ID = "com.opentaiko.mobile".freeze

out_dir = ARGV[0] || "usage"
FileUtils.mkdir_p(out_dir)

app_id = AscApi.find_app_id(BUNDLE_ID)

# A collection's meta.paging.total is the authoritative count without walking
# every page, so limit=1 is enough to read it.
def total_for(url)
  AscApi.get(url).dig("meta", "paging", "total")
end

summary = ["# OpenTaiko usage (TestFlight)", ""]

testers_total = total_for("/v1/betaTesters?filter[apps]=#{app_id}&limit=1")
summary << "Total TestFlight testers: #{testers_total}"
summary << ""
puts "Total TestFlight testers: #{testers_total}"

# Breakdown by invite type (EMAIL vs PUBLIC_LINK) and, when the API returns it,
# by overall tester state.
invite = Hash.new(0)
state = Hash.new(0)
AscApi.each_page("/v1/betaTesters?filter[apps]=#{app_id}&limit=200", max_pages: 1000) do |page, n|
  File.write(File.join(out_dir, "betaTesters_page#{n}.json"), JSON.pretty_generate(page))
  (page["data"] || []).each do |t|
    a = t["attributes"] || {}
    invite[a["inviteType"] || "UNKNOWN"] += 1
    state[a["state"]] += 1 if a["state"]
  end
end
summary << "## By invite type"
invite.each { |k, v| summary << "- #{k}: #{v}" }
summary << ""
unless state.empty?
  summary << "## By state"
  state.each { |k, v| summary << "- #{k}: #{v}" }
  summary << ""
end

summary << "## Beta groups"
AscApi.each_page("/v1/betaGroups?filter[app]=#{app_id}&limit=200", max_pages: 100) do |page, _n|
  (page["data"] || []).each do |g|
    name = g.dig("attributes", "name")
    gt = total_for("/v1/betaTesters?filter[betaGroups]=#{g["id"]}&limit=1")
    summary << "- #{name}: #{gt} tester(s)"
    puts "Group #{name}: #{gt}"
  end
end
summary << ""

# Per build, the count of testers with access to it (a proxy for reach, not an
# install or session count - those are not exposed by this API).
summary << "## Recent builds (testers with access)"
builds_page = AscApi.get("/v1/builds?filter[app]=#{app_id}&limit=10&sort=-uploadedDate")
File.write(File.join(out_dir, "builds.json"), JSON.pretty_generate(builds_page))
(builds_page["data"] || []).each do |b|
  ver = b.dig("attributes", "version")
  it = begin
    total_for("/v1/betaTesters?filter[builds]=#{b["id"]}&limit=1")
  rescue => e
    "n/a (#{e.message.split("\n").first})"
  end
  summary << "- build #{ver}: #{it} tester(s)"
end
summary << ""

File.write(File.join(out_dir, "summary.md"), summary.join("\n"))
puts "Wrote #{out_dir}/summary.md"
