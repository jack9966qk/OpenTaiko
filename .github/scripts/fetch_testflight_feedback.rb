# Fetches TestFlight tester feedback (screenshot and crash submissions) into an
# output directory: raw JSON pages, screenshot images, crash logs and a summary.md.
# Usage: bundle exec ruby .github/scripts/fetch_testflight_feedback.rb [out_dir]
# MAX_PAGES caps pagination per feedback type (200 items per page).
require "fileutils"
require_relative "asc_api"

BUNDLE_ID = "com.opentaiko.mobile".freeze

out_dir = ARGV[0] || "feedback"
max_pages = (ENV["MAX_PAGES"] || "10").to_i
FileUtils.mkdir_p(out_dir)

def item_line(item)
  a = item["attributes"] || {}
  comment = (a["comment"] || a["comments"] || "").to_s.strip.gsub(/\s+/, " ")
  meta = [a["createdDate"], a["deviceModel"], a["osVersion"]].compact.join(", ")
  "- #{meta}: #{comment.empty? ? "(no comment)" : comment}"
end

# Downloads every https URL found in the resource attributes best effort.
# The exact URL field names vary across API versions, so match defensively.
def download_attribute_urls(item, out_dir, prefix, default_ext)
  urls = JSON.generate(item["attributes"] || {}).scan(%r{https://[^"\\]+}).uniq
  urls.each_with_index do |url, i|
    ext = File.extname(URI(url).path)
    ext = default_ext if ext.empty?
    File.binwrite(File.join(out_dir, "#{prefix}_#{item["id"]}_#{i}#{ext}"), AscApi.raw_get(url))
  rescue => e
    warn "#{prefix} download failed for #{item["id"]}: #{e.message}"
  end
end

app_id = AscApi.find_app_id(BUNDLE_ID)
summary = ["# TestFlight feedback", ""]

{
  "screenshot_feedback" => "betaFeedbackScreenshotSubmissions?limit=200",
  "crash_feedback" => "betaFeedbackCrashSubmissions?limit=200&include=crashLog",
}.each do |name, query|
  items = []
  included = []
  more = AscApi.each_page("/v1/apps/#{app_id}/#{query}", max_pages: max_pages) do |page, n|
    File.write(File.join(out_dir, "#{name}_page#{n}.json"), JSON.pretty_generate(page))
    items.concat(page["data"] || [])
    included.concat(page["included"] || [])
  end
  summary << "## #{name}: #{items.length} item(s)#{more ? " (MAX_PAGES reached, more remain)" : ""}"
  items.each { |item| summary << item_line(item) }
  summary << ""
  puts "#{name}: #{items.length} item(s), #{included.length} included resource(s)"

  case name
  when "screenshot_feedback"
    items.each { |item| download_attribute_urls(item, out_dir, "screenshot", ".png") }
  when "crash_feedback"
    # Crash logs arrive in the included section of the same responses. A
    # submission whose log is no longer retained simply has nothing included.
    included.each do |log|
      File.write(File.join(out_dir, "crashlog_#{log["id"]}.json"), JSON.pretty_generate(log))
      download_attribute_urls(log, out_dir, "crashlog", ".txt")
    end
    summary << "#{included.length} crash log(s) still retained for the items above"
    summary << ""
  end
end

File.write(File.join(out_dir, "summary.md"), summary.join("\n"))
puts "Wrote #{out_dir}/"
