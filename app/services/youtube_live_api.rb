# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# Der schmale Zugang zur YouTube Live Streaming API.
#
# BEWUSST OHNE GEM: Gebraucht werden vier Aufrufe (laufende Übertragungen,
# geplante Übertragungen, Streamzustand, Beenden). Der offizielle
# `google-api-client` zieht dafür eine große Abhängigkeitskette in ein Image,
# das sonst ohne Google-Code auskommt, und sein Discovery-Mechanismus lädt beim
# ersten Aufruf ein mehrere Megabyte großes Schema nach -- in einem Cronjob, der
# alle fünf Minuten anspringt, ist das der teuerste Teil des Laufs.
#
# ANMELDUNG ÜBER EIN REFRESH-TOKEN, NICHT ÜBER EINEN API-SCHLÜSSEL: Das Beenden
# einer Übertragung ist ein schreibender Zugriff auf einen fremden Kanal; dafür
# gibt es nur OAuth. Das Token wird einmal von Hand am Arbeitsplatz erzeugt
# (dort steht ein Browser für den Zustimmungsdialog) und liegt danach als
# Umgebungsvariable am Container -- dasselbe Muster wie die SMTP-Zugangsdaten in
# config/environments/production.rb.
#
# Die drei Variablen:
#   YOUTUBE_CLIENT_ID, YOUTUBE_CLIENT_SECRET, YOUTUBE_REFRESH_TOKEN
#
# Fehlt eine davon, ist der Zugang schlicht nicht eingerichtet: Der Watchdog
# meldet das und tut nichts. Das ist der Normalzustand in Entwicklung und auf
# Staging, wo niemand den Produktionskanal beenden können soll.
class YoutubeLiveApi
  class Error < StandardError; end
  class NotConfigured < Error; end

  API_ROOT = 'https://www.googleapis.com/youtube/v3'
  TOKEN_URL = 'https://oauth2.googleapis.com/token'

  # Ein Cronjob darf nicht an einer hängenden Verbindung stehen bleiben: Der
  # nächste Lauf käme fünf Minuten später dazu, und nach einer Stunde lägen
  # zwölf Prozesse übereinander.
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 20

  ENV_KEYS = %w[YOUTUBE_CLIENT_ID YOUTUBE_CLIENT_SECRET YOUTUBE_REFRESH_TOKEN].freeze

  def self.configured?
    ENV_KEYS.all? { |key| ENV[key].present? }
  end

  def initialize
    return if self.class.configured?

    fehlend = ENV_KEYS.reject { |key| ENV[key].present? }
    raise NotConfigured, "YouTube-Zugang nicht eingerichtet, es fehlt: #{fehlend.join(', ')}"
  end

  # Alle laufenden Übertragungen des angemeldeten Kanals.
  #
  # `broadcastStatus` ist ein Filter, und die API erlaubt GENAU EINEN davon --
  # `mine: true` zusätzlich zu setzen quittiert sie mit `incompatibleParameters`.
  # Die Vorlage im Streaming-Ordner tat genau das; deshalb ist sie nie gelaufen.
  # Der Filter reicht auch allein: Angemeldet ist der Kanal selbst.
  def active_broadcasts
    broadcasts('active')
  end

  # Zustand und Ingest-Schlüssel je Stream-Ressource, als Hash über die
  # Stream-ID. `streamStatus` ist der Momentanwert: 'active' heißt, dass gerade
  # Bild ankommt.
  def streams(ids)
    ergebnis = {}
    Array(ids).compact.uniq.each_slice(50) do |block|
      antwort = get('liveStreams', part: 'id,cdn,status', id: block.join(','), maxResults: 50)
      antwort.fetch('items', []).each do |item|
        ergebnis[item['id']] = {
          status: item.dig('status', 'streamStatus'),
          key: item.dig('cdn', 'ingestionInfo', 'streamName')
        }
      end
    end
    ergebnis
  end

  # Beendet eine laufende Übertragung. Kostet 50 Kontingenteinheiten, die
  # Abfragen dagegen je eine.
  def complete!(broadcast_id)
    post('liveBroadcasts/transition', id: broadcast_id, broadcastStatus: 'complete', part: 'id,status')
  end

  private

  def broadcasts(status)
    ergebnis = []
    seite = nil

    loop do
      params = { part: 'id,snippet,contentDetails', broadcastStatus: status,
                 broadcastType: 'all', maxResults: 50 }
      params[:pageToken] = seite if seite
      antwort = get('liveBroadcasts', **params)

      antwort.fetch('items', []).each do |item|
        ergebnis << {
          id: item['id'],
          title: item.dig('snippet', 'title'),
          stream_id: item.dig('contentDetails', 'boundStreamId')
        }
      end

      seite = antwort['nextPageToken']
      break if seite.blank?
    end

    ergebnis
  end

  # Ein Zugangstoken gilt eine Stunde, ein Lauf dauert Sekunden -- einmal je
  # Instanz holen genügt, gespeichert wird es nicht.
  def access_token
    @access_token ||= begin
      antwort = form_post(URI(TOKEN_URL),
                          client_id: ENV.fetch('YOUTUBE_CLIENT_ID'),
                          client_secret: ENV.fetch('YOUTUBE_CLIENT_SECRET'),
                          refresh_token: ENV.fetch('YOUTUBE_REFRESH_TOKEN'),
                          grant_type: 'refresh_token')
      antwort['access_token'].presence ||
        raise(Error, 'Antwort der Token-Ausgabe enthält kein access_token')
    end
  end

  def get(pfad, **params)
    uri = URI("#{API_ROOT}/#{pfad}")
    uri.query = URI.encode_www_form(params)
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{access_token}"
    ausfuehren(uri, request)
  end

  def post(pfad, **params)
    uri = URI("#{API_ROOT}/#{pfad}")
    uri.query = URI.encode_www_form(params)
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{access_token}"
    request['Content-Length'] = '0'
    ausfuehren(uri, request)
  end

  def form_post(uri, **params)
    request = Net::HTTP::Post.new(uri)
    request.set_form_data(params)
    ausfuehren(uri, request)
  end

  def ausfuehren(uri, request)
    antwort = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                                      open_timeout: OPEN_TIMEOUT,
                                                      read_timeout: READ_TIMEOUT) do |http|
      http.request(request)
    end

    unless antwort.is_a?(Net::HTTPSuccess)
      # Der Körper der Fehlerantwort trägt den Grund ("quotaExceeded",
      # "invalid_grant", "incompatibleParameters"). Ohne ihn steht im Log nur
      # eine Statuszeile, und der Unterschied zwischen "Kontingent alle" und
      # "Token widerrufen" ist genau der zwischen Abwarten und Handeln.
      raise Error, "#{request.method} #{uri.path} → #{antwort.code}: #{antwort.body.to_s[0, 500]}"
    end

    antwort.body.presence ? JSON.parse(antwort.body) : {}
  rescue JSON::ParserError => e
    raise Error, "Antwort von #{uri.path} ist kein JSON: #{e.message}"
  end
end
