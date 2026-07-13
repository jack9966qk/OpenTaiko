# Updates the TestFlight beta app description (Test Information) from a text file.
# Usage: bundle exec ruby .github/scripts/update_beta_description.rb <file> [locale]
require_relative "asc_api"

BUNDLE_ID = "com.opentaiko.mobile".freeze
MAX_LENGTH = 4000

file = ARGV.fetch(0)
locale = ARGV[1] || "en-US"
description = File.read(file).strip
abort("#{file} is empty") if description.empty?
if description.length > MAX_LENGTH
  abort("Description is #{description.length} characters, the TestFlight limit is #{MAX_LENGTH}")
end

app_id = AscApi.find_app_id(BUNDLE_ID)
localizations = AscApi.get("/v1/apps/#{app_id}/betaAppLocalizations")["data"] || []
loc = localizations.find { |l| l.dig("attributes", "locale") == locale } || localizations.first

if loc
  AscApi.patch("/v1/betaAppLocalizations/#{loc["id"]}", {
    data: { type: "betaAppLocalizations", id: loc["id"], attributes: { description: description } },
  })
  puts "Updated beta app description (#{loc.dig("attributes", "locale")}, #{description.length} chars)"
else
  AscApi.post("/v1/betaAppLocalizations", {
    data: {
      type: "betaAppLocalizations",
      attributes: { locale: locale, description: description },
      relationships: { app: { data: { type: "apps", id: app_id } } },
    },
  })
  puts "Created beta app description (#{locale}, #{description.length} chars)"
end
