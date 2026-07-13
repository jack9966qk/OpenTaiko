# Minimal App Store Connect API client for workflow scripts.
# Auth comes from the same environment variables the fastlane lanes use:
# APP_STORE_CONNECT_API_KEY_KEY_ID / _ISSUER_ID / _KEY (PEM or base64 PEM).
require "base64"
require "json"
require "jwt"
require "net/http"
require "openssl"
require "uri"

module AscApi
  BASE = "https://api.appstoreconnect.apple.com".freeze

  def self.token
    key_content = ENV.fetch("APP_STORE_CONNECT_API_KEY_KEY")
    key_content = Base64.decode64(key_content) unless key_content.include?("-----BEGIN")
    key = OpenSSL::PKey::EC.new(key_content)
    now = Time.now.to_i
    payload = {
      iss: ENV.fetch("APP_STORE_CONNECT_API_KEY_ISSUER_ID"),
      iat: now,
      exp: now + 15 * 60,
      aud: "appstoreconnect-v1",
    }
    JWT.encode(payload, key, "ES256", kid: ENV.fetch("APP_STORE_CONNECT_API_KEY_KEY_ID"))
  end

  def self.request(method, url, body: nil)
    uri = url.start_with?("http") ? URI(url) : URI("#{BASE}#{url}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = case method
          when :patch then Net::HTTP::Patch.new(uri)
          when :post then Net::HTTP::Post.new(uri)
          else Net::HTTP::Get.new(uri)
          end
    req["Authorization"] = "Bearer #{token}"
    if body
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
    end
    res = http.request(req)
    unless res.code.to_i.between?(200, 299)
      raise "#{method.to_s.upcase} #{uri.path} failed: #{res.code} #{res.body}"
    end
    res.body.to_s.empty? ? {} : JSON.parse(res.body)
  end

  def self.get(url)
    request(:get, url)
  end

  def self.patch(url, body)
    request(:patch, url, body: body)
  end

  def self.post(url, body)
    request(:post, url, body: body)
  end

  # Unauthenticated download for presigned asset URLs (screenshots etc.).
  def self.raw_get(url)
    res = Net::HTTP.get_response(URI(url))
    res = Net::HTTP.get_response(URI(res["location"])) if res.is_a?(Net::HTTPRedirection)
    raise "asset GET failed: #{res.code}" unless res.code.to_i.between?(200, 299)
    res.body
  end

  # Yields each page of a paginated collection. Returns the next-page URL when
  # max_pages was reached with more data remaining, nil otherwise.
  def self.each_page(url, max_pages:)
    pages = 0
    while url && pages < max_pages
      page = get(url)
      pages += 1
      yield page, pages
      url = page.dig("links", "next")
    end
    url
  end

  def self.find_app_id(bundle_id)
    apps = get("/v1/apps?filter[bundleId]=#{bundle_id}")["data"]
    raise "No app found for bundle id #{bundle_id}" if apps.nil? || apps.empty?
    apps.first["id"]
  end
end
