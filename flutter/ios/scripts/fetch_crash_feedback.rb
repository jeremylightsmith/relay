#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Fetch TestFlight beta crash feedback for Relay from the App Store Connect
# API — the reports testers file from TestFlight's "Send crash report".
# Each submission is mapped to its TestFlight BUILD number, which is what
# tells you whether a reported crash predates a shipped fix (RLY-99's
# second rejection was exactly that: the fixed build was uploaded two
# minutes before the retest, so the phone was still on the pre-fix build).
#
# Auth: a fastlane-style API key JSON ({"key_id":…,"issuer_id":…,"key":"<PEM>"}).
# Default is the account-level key already on this machine; override with
#   ASC_KEY_JSON=/path/to/key.json
#
# Usage:
#   ruby fetch_crash_feedback.rb            # list submissions, newest first
#   ruby fetch_crash_feedback.rb <sub-id>   # print one report's full crash log

require 'openssl'
require 'json'
require 'base64'
require 'net/http'
require 'uri'

BUNDLE_ID = 'com.jeremylightsmith.Relay'
KEY_JSON = File.expand_path(
  ENV.fetch('ASC_KEY_JSON',
            '~/.appstoreconnect/private_keys/spicytimer_asc_api_key.json'))

def b64(s) = Base64.urlsafe_encode64(s).delete('=')

def token
  cfg = JSON.parse(File.read(KEY_JSON))
  key = OpenSSL::PKey.read(cfg.fetch('key'))
  now = Time.now.to_i
  header = { 'alg' => 'ES256', 'kid' => cfg.fetch('key_id'), 'typ' => 'JWT' }
  payload = { 'iss' => cfg.fetch('issuer_id'), 'iat' => now, 'exp' => now + 600,
              'aud' => 'appstoreconnect-v1' }
  input = "#{b64(JSON.generate(header))}.#{b64(JSON.generate(payload))}"
  # JOSE ES256 wants the raw 64-byte r||s signature, not OpenSSL's DER.
  der = key.sign(OpenSSL::Digest.new('SHA256'), input)
  r, s = OpenSSL::ASN1.decode(der).value.map { |x| x.value.to_s(2) }
  "#{input}.#{b64(r.rjust(32, "\x00".b) + s.rjust(32, "\x00".b))}"
end

def get(path)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{token}"
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  abort "HTTP #{res.code}: #{res.body}" unless res.code.to_i == 200
  JSON.parse(res.body)
end

if (id = ARGV[0])
  puts get("/v1/betaFeedbackCrashSubmissions/#{id}/crashLog")
    .dig('data', 'attributes', 'logText')
  exit
end

app_id = get("/v1/apps?filter[bundleId]=#{BUNDLE_ID}").dig('data', 0, 'id')
abort "no app found for #{BUNDLE_ID}" unless app_id
feed = get("/v1/apps/#{app_id}/betaFeedbackCrashSubmissions" \
           '?include=build&sort=-createdDate&limit=50')
builds = (feed['included'] || []).to_h { |b| [b['id'], b.dig('attributes', 'version')] }
if feed['data'].empty?
  puts 'no crash feedback submissions'
else
  feed['data'].each do |sub|
    a = sub['attributes']
    build = builds[sub.dig('relationships', 'build', 'data', 'id')] || '?'
    puts "#{a['createdDate']}  build=#{build}  #{a['deviceModel']} " \
         "iOS #{a['osVersion']}  #{sub['id']}  comment=#{a['comment'].inspect}"
  end
end
