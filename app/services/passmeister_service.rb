require 'net/http'
require 'json'

class PassmeisterService
  class Error < StandardError; end

  PASS_TYPE_ID = 'P428195'.freeze
  API_BASE = 'https://www.passmeister.com/api/v1'.freeze
  LIZENZCHECK_URL = 'https://sr.floorball.de/lizenzcheck/'.freeze

  def self.create_or_update_pass(referee)
    pass_id = "referee-#{referee.lizenznummer}"
    club_name = referee.club&.name.to_s
    barcode_link = "#{LIZENZCHECK_URL}?#{URI.encode_www_form(q: referee.lizenznummer)}"

    uri = URI("#{API_BASE}/pass")
    uri.query = URI.encode_www_form(passTypeId: PASS_TYPE_ID, passId: pass_id)

    payload = {
      'field.memberName.value'   => "#{referee.vorname} #{referee.nachname}",
      'field.memberNumber.value' => referee.lizenznummer.to_s,
      'field.club.value.de'      => club_name,
      'field.club.value.en'      => club_name,
      'barcodeValue'             => barcode_link,
      'barcodeAlternativeText'   => referee.lizenznummer.to_s,
      'expiresAt'                => next_rotation_expiry.utc.iso8601
    }

    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{api_key}"
    req.body = payload.to_json

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(req)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "Passmeister-Fehler #{response.code}: #{response.body.to_s[0, 500]}"
    end

    JSON.parse(response.body)
  rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET,
         Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    raise Error, "Passmeister nicht erreichbar: #{e.message}"
  rescue JSON::ParserError => e
    raise Error, "Passmeister-Antwort ungültig: #{e.message}"
  end

  def self.next_rotation_expiry
    base = 2030
    target = base
    target += 4 while target <= Date.today.year
    Time.utc(target, 6, 30, 23, 59, 59)
  end

  def self.api_key
    key = ENV['PASSMEISTER_API_KEY'].presence || Rails.application.credentials.passmeister_api_key
    raise Error, 'PASSMEISTER_API_KEY ist nicht konfiguriert' if key.blank?

    key
  end
end
