require 'net/http'
require 'json'

class PassmeisterService
  TEMPLATE_ID = 'P428195'.freeze
  API_BASE = 'https://www.passmeister.com/api/v1'.freeze

  def self.create_or_update_pass(referee)
    uri = URI("#{API_BASE}/pass")
    payload = {
      'passId'     => "referee-#{referee.lizenznummer}",
      'templateId' => TEMPLATE_ID,
      'memberName' => { 'value' => "#{referee.vorname} #{referee.nachname}" },
      'club'       => { 'value' => referee.club&.name.to_s },
      'memberNumber' => { 'value' => referee.lizenznummer.to_s },
      'barcode'    => { 'label' => referee.lizenznummer.to_s },
      'expirationDate' => next_rotation_expiry.iso8601
    }

    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{api_key}"
    req.body = payload.to_json

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(req)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise "Passmeister-Fehler #{response.code}: #{response.body}"
    end

    JSON.parse(response.body)
  end

  def self.next_rotation_expiry
    base = 2030
    target = base
    target += 4 while target <= Date.today.year
    Date.new(target, 6, 30)
  end

  def self.api_key
    ENV.fetch('PASSMEISTER_API_KEY') do
      Rails.application.credentials.passmeister_api_key
    end
  end
end
