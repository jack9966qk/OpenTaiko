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

app_id = AscApi.find_app_id(BUNDLE_ID)
summary = ["# TestFlight feedback", ""]

{
  "screenshot_feedback" => "betaFeedbackScreenshotSubmissions",
  "crash_feedback" => "betaFeedbackCrashSubmissions",
}.each do |name, resource|
  items = []
  more = AscApi.each_page("/v1/apps/#{app_id}/#{resource}?limit=200", max_pages: max_pages) do |page, n|
    File.write(File.join(out_dir, "#{name}_page#{n}.json"), JSON.pretty_generate(page))
    items.concat(page["data"] || [])
  end
  summary << "## #{name}: #{items.length} item(s)#{more ? " (MAX_PAGES reached, more remain)" : ""}"
  items.each { |item| summary << item_line(item) }
  summary << ""
  puts "#{name}: #{items.length} item(s)"

  case name
  when "screenshot_feedback"
    # The image URL field name varies across API versions, so collect every
    # https URL in the attributes and download them best effort.
    items.each do |item|
      urls = JSON.generate(item["attributes"] || {}).scan(%r{https://[^"\\]+}).uniq
      urls.each_with_index do |url, i|
        ext = File.extname(URI(url).path)
        ext = ".png" if ext.empty?
        File.binwrite(File.join(out_dir, "screenshot_#{item["id"]}_#{i}#{ext}"), AscApi.raw_get(url))
      rescue => e
        warn "screenshot download failed for #{item["id"]}: #{e.message}"
      end
    end
  when "crash_feedback"
    items.each do |item|
      log = AscApi.get("/v1/#{resource}/#{item["id"]}/crashLog")
      File.write(File.join(out_dir, "crashlog_#{item["id"]}.json"), JSON.pretty_generate(log))
    rescue => e
      warn "crash log fetch failed for #{item["id"]}: #{e.message}"
    end
  end
end

File.write(File.join(out_dir, "summary.md"), summary.join("\n"))
puts "Wrote #{out_dir}/"
