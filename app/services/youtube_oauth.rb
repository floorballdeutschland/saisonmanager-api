# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# Tauscht den Anmeldecode aus dem Browser gegen einen dauerhaften Zugang des
# Livestream-Waechters.
#
# WARUM DER CODE AUS DEM BROWSER KOMMT UND NICHT DER SERVER UMLEITET: Der
# Streaming-Bereich meldet sich fuer das Anlegen der Uebertragungen ohnehin bei
# Google an (`YoutubeService`, Zugriffstoken fuer eine Stunde). Derselbe
# Dialog liefert im Code-Modell zusaetzlich einen Code, den nur der Server
# einloesen kann -- und nur dabei entsteht ein Refresh-Token. Der Server
# braucht so keine eigene Umleitungsadresse und keine Sitzung bei Google.
#
# WARUM ES DEN WEG UEBERHAUPT GIBT: Bisher stand der Refresh-Token als
# `YOUTUBE_REFRESH_TOKEN` am Container. Widerruft ihn jemand oder verliert das
# Konto den Kanal, steht der Waechter still, und das Erneuern braucht SSH, eine
# Handzeile und einen Neustart.
class YoutubeOauth
  class Error < StandardError; end

  # Google hat zugestimmt, aber keinen dauerhaften Zugang ausgegeben. Passiert,
  # wenn dasselbe Konto der Anwendung schon einmal zugestimmt hat: Den
  # Refresh-Token gibt es nur bei der ERSTEN Zustimmung wieder heraus.
  class NoRefreshToken < Error; end

  # Der zugestimmte Kanal darf nicht senden. Das ist kein Randfall, sondern der
  # Fall, der beim Einrichten am 21.09.2026 eine Stunde gekostet hat: Am Konto
  # haengen ZWEI Kanaele namens „floorball deutschland", und der leere Testkanal
  # antwortet auf jeden Live-Endpunkt mit `liveStreamingNotEnabled`. Ohne diese
  # Pruefung waere der Zugang gespeichert, die Oberflaeche meldete Erfolg, und
  # der Waechter scheiterte erst am Spieltag.
  class LiveStreamingDisabled < Error; end

  TOKEN_URL = 'https://oauth2.googleapis.com/token'
  API_ROOT = 'https://www.googleapis.com/youtube/v3'
  SCOPE = 'https://www.googleapis.com/auth/youtube.force-ssl'
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 20

  ENV_KEYS = %w[YOUTUBE_WEB_CLIENT_ID YOUTUBE_WEB_CLIENT_SECRET].freeze

  def self.configured?
    ENV_KEYS.all? { |key| ENV[key].present? } && StreamCredential.key?
  end

  def self.fehlende_einstellungen
    fehlend = ENV_KEYS.reject { |key| ENV[key].present? }
    fehlend << StreamCredential::KEY_ENV unless StreamCredential.key?
    fehlend
  end

  def initialize(code:, redirect_uri: nil)
    @code = code.to_s
    @redirect_uri = redirect_uri.presence
    raise Error, 'Kein Anmeldecode uebergeben' if @code.blank?
  end

  # Loest den Code ein, prueft den Kanal und speichert den Zugang.
  def verbinden!(user: nil)
    token = code_einloesen
    refresh = token['refresh_token'].presence
    raise NoRefreshToken if refresh.nil?

    # Kein `fetch`: Ein `KeyError` faenge kein rescue im Controller und
    # schluege als 500 durch, wo jeder andere Fehlschlag hier eine 422 mit
    # Begruendung liefert.
    zugriff = token['access_token'].presence
    raise Error, 'Antwort der Token-Ausgabe enthaelt kein access_token' if zugriff.nil?

    kanal = kanal_lesen(zugriff)
    live_pruefen(zugriff)

    satz = StreamCredential.current || StreamCredential.new
    satz.refresh_token = refresh
    satz.client_id = ENV.fetch('YOUTUBE_WEB_CLIENT_ID', nil)
    satz.channel_id = kanal[:id]
    satz.channel_title = kanal[:title]
    satz.scope = token['scope'].presence || SCOPE
    satz.connected_at = Time.current
    satz.connected_by_user_id = user&.id
    satz.save!
    satz
  end

  # Widerruft den Zugang bei Google.
  #
  # OHNE DIESEN SCHRITT IST DAS TRENNEN EINE SACKGASSE: Google gibt einen
  # Refresh-Token nur bei der ERSTEN Zustimmung eines Kontos heraus. Wer
  # trennt und sich danach mit demselben Konto neu verbindet, bekaeme keinen
  # neuen Token und liefe in `NoRefreshToken` -- ausgerechnet auf dem Weg, der
  # den Zugang wieder in Ordnung bringen soll.
  #
  # Bestmoeglich und nie fatal: Ist der Token schon widerrufen oder Google
  # nicht erreichbar, bleibt das oertliche Loeschen trotzdem richtig.
  def self.revoke(refresh_token)
    return false if refresh_token.blank?

    uri = URI('https://oauth2.googleapis.com/revoke')
    anfrage = Net::HTTP::Post.new(uri)
    anfrage.set_form_data(token: refresh_token)
    antwort = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                                      open_timeout: OPEN_TIMEOUT,
                                                      read_timeout: READ_TIMEOUT) do |http|
      http.request(anfrage)
    end
    antwort.is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end

  private

  # ZWEI ANLAEUFE, UND DAS IST KEINE RATEREI: Im Aufklappfenster des
  # Code-Modells setzt Google die Umleitungsadresse selbst -- je nach Version
  # der Bibliothek auf den Ursprung der Seite oder auf den Sonderwert
  # `postmessage`. Beim Einloesen muss GENAU derselbe Wert stehen, sonst
  # antwortet Google mit `redirect_uri_mismatch`. Die Alternative waere, den
  # Fall im Frontend zu raten; hier kostet er einen zweiten Aufruf und ist
  # damit erledigt.
  def code_einloesen
    versuche = [@redirect_uri, 'postmessage'].compact.uniq
    letzter = nil

    versuche.each do |ziel|
      antwort = token_abruf(ziel)
      return antwort unless antwort['error']

      letzter = antwort
      next if antwort['error'] == 'redirect_uri_mismatch'

      break
    end

    raise Error, fehlertext(letzter)
  end

  def token_abruf(redirect_uri)
    post_form(URI(TOKEN_URL),
              code: @code,
              client_id: ENV.fetch('YOUTUBE_WEB_CLIENT_ID'),
              client_secret: ENV.fetch('YOUTUBE_WEB_CLIENT_SECRET'),
              redirect_uri: redirect_uri,
              grant_type: 'authorization_code')
  end

  def fehlertext(antwort)
    return 'Google hat den Anmeldecode nicht angenommen' if antwort.blank?

    [antwort['error'], antwort['error_description']].compact.join(': ')
  end

  # Der Titel allein sagt NICHT, welcher Kanal es ist -- die beiden gleichnamigen
  # unterscheiden sich nur an der Kennung und daran, dass der echte Videos hat.
  def kanal_lesen(zugriff)
    antwort = api_get(zugriff, 'channels', part: 'snippet,statistics', mine: 'true')
    eintrag = antwort.fetch('items', []).first
    raise Error, 'An diesem Google-Konto haengt kein YouTube-Kanal' if eintrag.nil?

    { id: eintrag['id'],
      title: eintrag.dig('snippet', 'title'),
      videos: eintrag.dig('statistics', 'videoCount') }
  end

  def live_pruefen(zugriff)
    api_get(zugriff, 'liveBroadcasts', part: 'id', broadcastStatus: 'active',
                                       broadcastType: 'all', maxResults: 1)
  rescue Error => e
    raise LiveStreamingDisabled if e.message.include?('liveStreamingNotEnabled')

    raise
  end

  def api_get(zugriff, pfad, **params)
    uri = URI("#{API_ROOT}/#{pfad}")
    uri.query = URI.encode_www_form(params)
    anfrage = Net::HTTP::Get.new(uri)
    anfrage['Authorization'] = "Bearer #{zugriff}"
    antwort = ausfuehren(uri, anfrage)
    return antwort unless antwort['error']

    raise Error, rohtext(antwort)
  end

  # Der ROHE Grund gehoert in die Ausnahme, nicht der uebersetzte Fliesstext:
  # Auf Prosa zu pruefen bricht, sobald Google sie umformuliert oder in einer
  # anderen Sprache liefert.
  def rohtext(antwort)
    gruende = antwort.dig('error', 'errors').to_a.filter_map { |e| e['reason'] }
    nachricht = antwort.dig('error', 'message')
    [gruende.join(','), nachricht].reject(&:blank?).join(' ')
  end

  def post_form(uri, **felder)
    anfrage = Net::HTTP::Post.new(uri)
    anfrage.set_form_data(felder)
    ausfuehren(uri, anfrage)
  end

  def ausfuehren(uri, anfrage)
    antwort = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                                      open_timeout: OPEN_TIMEOUT,
                                                      read_timeout: READ_TIMEOUT) do |http|
      http.request(anfrage)
    end
    koerper = JSON.parse(antwort.body.presence || '{}')
    # DER STATUS ZAEHLT, nicht nur der Inhalt: Eine 500 mit leerem Koerper kaeme
    # sonst als `{}` zurueck, und die Livestream-Pruefung -- der Riegel, um den
    # herum dieser Dienst gebaut ist -- ginge still durch. Ein Fehlerkoerper
    # darf dagegen zurueck: Google beschreibt darin `redirect_uri_mismatch`,
    # und genau daran haengt der zweite Anlauf.
    return koerper if antwort.is_a?(Net::HTTPSuccess) || koerper['error'].present?

    raise Error, "Google antwortete mit #{antwort.code}"
  rescue JSON::ParserError
    raise Error, "Unlesbare Antwort von Google (#{antwort&.code})"
  rescue Timeout::Error, SystemCallError, SocketError, IOError,
         OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError => e
    # Dieselbe Lehre wie beim Waechter: Netzfehler sind keine Google-Fehler und
    # wuerden von keinem `rescue` im Projekt gefangen.
    raise Error, "Google nicht erreichbar: #{e.class}"
  end
end
