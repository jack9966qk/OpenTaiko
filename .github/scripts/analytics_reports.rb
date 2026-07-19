# Pulls real usage analytics from App Store Connect: active devices,
# installations, sessions and (optionally) download units. Unlike the tester
# count, this data comes from the Analytics Reports API, which is asynchronous.
#
# Modes (first CLI arg, default "fetch"):
#   provision  POST a one-time ONGOING report request for the app. Apple takes
#              up to ~48h to first populate it. Run this once, then use fetch.
#   fetch      Find the ONGOING request, download the latest instances of the
#              usage reports, gunzip the CSVs and summarise their headers/totals.
#
# Env:
#   GRANULARITY    DAILY | WEEKLY | MONTHLY  (default DAILY)
#   VENDOR_NUMBER  when set, also pulls a Sales and Trends download-units report
#   REPORT_DATE    sales report date YYYY-MM-DD (default: 3 days ago)
# Usage: bundle exec ruby .github/scripts/analytics_reports.rb [provision|fetch] [out_dir]
require "fileutils"
require "stringio"
require "zlib"
require "date"
require_relative "asc_api"

BUNDLE_ID = "com.opentaiko.mobile".freeze

# Report names we care about. Matched case-insensitively as substrings so small
# wording changes on Apple's side still resolve.
WANTED_REPORTS = [
  "App Store Installations and Deletions",
  "App Sessions",
  "App Store Discovery and Engagement",
  "App Crashes",
].freeze

mode = ARGV[0] || "fetch"
out_dir = ARGV[1] || "analytics"
granularity = (ENV["GRANULARITY"] || "DAILY").upcase
FileUtils.mkdir_p(out_dir)

app_id = AscApi.find_app_id(BUNDLE_ID)

def ongoing_request(app_id)
  reqs = AscApi.get("/v1/apps/#{app_id}/analyticsReportRequests")["data"] || []
  reqs.find { |r| r.dig("attributes", "accessType") == "ONGOING" && !r.dig("attributes", "stoppedDueToInactivity") }
end

# Gunzips a downloaded segment/report body when it is gzip, else returns as-is.
def gunzip(bytes)
  return bytes unless bytes[0, 2].bytes == [0x1f, 0x8b]
  Zlib::GzipReader.new(StringIO.new(bytes)).read
end

# Splits the header row on whichever delimiter (tab or comma) yields more cells.
def delimiter_for(header)
  header.count("\t") >= header.count(",") ? "\t" : ","
end

if mode == "provision"
  existing = ongoing_request(app_id)
  if existing
    puts "ONGOING analytics report request already exists: #{existing["id"]}"
  else
    body = {
      data: {
        type: "analyticsReportRequests",
        attributes: { accessType: "ONGOING" },
        relationships: { app: { data: { type: "apps", id: app_id } } },
      },
    }
    res = AscApi.post("/v1/analyticsReportRequests", body)
    puts "Created ONGOING analytics report request: #{res.dig("data", "id")}"
    puts "Apple takes up to ~48h to first populate reports. Run fetch after that."
  end
  exit 0
end

# fetch mode
req = ongoing_request(app_id)
if req.nil?
  warn "No ONGOING analytics report request found. Run this script with 'provision' first, then wait for Apple to populate (up to ~48h)."
  exit 1
end
puts "Using analytics report request #{req["id"]}"

summary = ["# OpenTaiko usage analytics (#{granularity})", ""]

reports = []
AscApi.each_page("/v1/analyticsReportRequests/#{req["id"]}/reports?limit=200", max_pages: 20) do |page, _n|
  reports.concat(page["data"] || [])
end
summary << "Reports available: #{reports.map { |r| r.dig("attributes", "name") }.compact.join("; ")}"
summary << ""

selected = reports.select do |r|
  name = (r.dig("attributes", "name") || "").downcase
  WANTED_REPORTS.any? { |w| name.include?(w.downcase) }
end
puts "Selected #{selected.length} report(s) of #{reports.length}"

selected.each do |report|
  name = report.dig("attributes", "name")
  slug = name.to_s.gsub(/[^a-zA-Z0-9]+/, "_")
  instances = AscApi.get("/v1/analyticsReports/#{report["id"]}/instances?filter[granularity]=#{granularity}&limit=200")["data"] || []
  # Newest processing date first.
  latest = instances.max_by { |i| i.dig("attributes", "processingDate").to_s }
  if latest.nil?
    summary << "## #{name}: no #{granularity} instance yet"
    summary << ""
    next
  end
  proc_date = latest.dig("attributes", "processingDate")
  segments = AscApi.get("/v1/analyticsReportInstances/#{latest["id"]}/segments")["data"] || []
  summary << "## #{name} (#{proc_date})"
  segments.each_with_index do |seg, i|
    url = seg.dig("attributes", "url")
    next unless url
    csv = gunzip(AscApi.raw_get(url))
    path = File.join(out_dir, "#{slug}_#{proc_date}_#{i}.csv")
    File.write(path, csv)
    lines = csv.split("\n")
    header = lines.first.to_s
    delim = delimiter_for(header)
    cols = header.split(delim)
    rows = lines.length - 1
    summary << "- segment #{i}: #{rows} row(s); columns: #{cols.join(" | ")}"
    # Best-effort headline: sum any obviously numeric count column.
    cols.each_with_index do |col, ci|
      next unless col =~ /count|sessions|devices|installations|units|active/i
      total = lines[1..].sum do |ln|
        v = ln.split(delim)[ci]
        v.to_s.gsub(",", "").to_f
      end
      summary << "  - sum(#{col}) = #{total.round}"
    end
  end
  summary << ""
end

# Optional Sales and Trends download-units report (needs a vendor number and a
# Finance/Sales/Admin role on the API key).
vendor = ENV["VENDOR_NUMBER"]
if vendor && !vendor.empty?
  report_date = ENV["REPORT_DATE"]
  report_date = (Date.today - 3).strftime("%Y-%m-%d") if report_date.nil? || report_date.empty?
  q = "filter[frequency]=DAILY&filter[reportType]=SALES&filter[reportSubType]=SUMMARY" \
      "&filter[vendorNumber]=#{vendor}&filter[version]=1_1&filter[reportDate]=#{report_date}"
  begin
    body = gunzip(AscApi.raw_get_authed("/v1/salesReports?#{q}"))
    File.write(File.join(out_dir, "sales_#{report_date}.tsv"), body)
    lines = body.split("\n")
    header = (lines.first || "").split("\t")
    units_i = header.index("Units")
    total_units = units_i ? lines[1..].sum { |ln| ln.split("\t")[units_i].to_i } : nil
    summary << "## Sales (downloads) #{report_date}"
    summary << "- rows: #{lines.length - 1}#{total_units ? ", total units: #{total_units}" : ""}"
    summary << ""
  rescue => e
    summary << "## Sales #{report_date}: unavailable (#{e.message.split("\n").first})"
    summary << ""
  end
end

File.write(File.join(out_dir, "summary.md"), summary.join("\n"))
puts "Wrote #{out_dir}/summary.md"
