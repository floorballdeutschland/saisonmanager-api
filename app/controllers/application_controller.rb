class ApplicationController < ActionController::Base
  include ActionController::MimeResponds
  protect_from_forgery with: :exception
  before_action :authenticate_user
  before_action :save_current_user # https://gist.github.com/kule/9425fb7d4c2a13e556ef
  before_action :set_paper_trail_whodunnit
  after_action :set_csrf_cookie
  after_action :track_api_key_usage

  # Wie lange öffentliche Live-Daten fremden API-Keys vorenthalten werden.
  # Zugesagt in der Nutzungsvereinbarung (api_terms.rb) und in der
  # Entwicklerdokumentation.
  LIVE_DATA_DELAY = 10.minutes

  # rescue_from-Handler werden von Rails in umgekehrter Definitionsreihenfolge
  # geprüft: Der zuletzt passende (= zuerst definierte) fängt zuletzt. Deshalb
  # steht der generische StandardError-Fallback OBEN und die spezifischen
  # Handler darunter, damit sie zuerst greifen.
  rescue_from StandardError do |e|
    # In dev/test durchreichen, damit Stacktraces sichtbar bleiben und
    # Test-Suiten nicht maskiert werden.
    raise if Rails.env.development? || Rails.env.test?

    Rails.logger.error("#{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    Sentry.capture_exception(e) if defined?(Sentry)
    render json: { success: false, message: 'Server-Fehler.' }, status: :internal_server_error
  end

  rescue_from ActionController::InvalidAuthenticityToken do
    render json: { success: false, message: 'CSRF token ungültig.' }, status: :forbidden
  end

  rescue_from ActiveRecord::RecordNotFound do
    render json: { success: false, message: 'Nicht gefunden.' }, status: :not_found
  end

  rescue_from ActionController::ParameterMissing, ActionController::UnpermittedParameters do |e|
    render json: { success: false, message: e.message }, status: :unprocessable_entity
  end

  rescue_from ActiveRecord::RecordInvalid do |e|
    render json: { success: false, message: e.message, errors: e.record.errors }, status: :unprocessable_entity
  end

  private

  # CSRF nur für authentifizierte Requests erzwingen
  def verified_request?
    super || !current_user
  end

  def set_csrf_cookie
    cookies['XSRF-TOKEN'] = {
      value: form_authenticity_token,
      secure: Rails.env.production?,
      same_site: :strict
    }
  end

  def authenticate_user
    @user = current_user
    render json: { success: false, message: 'Not authenticated' }, status: 401 unless @user
  end

  def authenticate_public_request
    return if current_user

    raw_key = request.headers['X-Api-Key']
    # Der sperrige Name ist Absicht: Ein schlichtes @api_key kollidiert mit
    # Controllern, die einen ApiKey-Datensatz verwalten (Admin::ApiKeysController).
    # Deren Fund würde den Request sonst als API-Key-Zugriff ausgeben, mit
    # verzögerten Daten und falschen Zahlen in der Nutzungsstatistik.
    @authenticated_api_key = ApiKey.authenticate(raw_key)
    return if @authenticated_api_key

    render json: { success: false, message: 'API key required' }, status: :unauthorized
  end

  def api_key_request?
    @authenticated_api_key.present?
  end

  # True, wenn die Antwort verzögert werden muss: Der Zugriff kommt über einen
  # API-Key ohne Echtzeit-Freigabe. Cookie-Sessions (eigenes Frontend,
  # angemeldete Nutzer) sind nie betroffen.
  def delay_live_data?
    api_key_request? && !@authenticated_api_key&.realtime
  end

  # Entfernt frische Ereignisse aus einem Spiel, bevor daraus eine Antwort
  # gebaut wird. Wirkt auf alles, was sich aus `events` ableitet, also auch auf
  # Spielstand und Ergebnis-String.
  #
  # Verändert die Instanz absichtlich in place und wird deshalb nur auf frisch
  # geladenen Objekten aufgerufen, die danach nicht gespeichert werden.
  def strip_delayed_events!(game)
    return game unless delay_live_data?
    # Beendete Spiele bleiben unangetastet. Game#result rechnet den Stand
    # vollständig aus `events`; ein gefiltertes Ereignis verzögert das Ergebnis
    # also nicht, sondern ergibt ein ANDERES. Bei einem beendeten Spiel stünde
    # damit ein falscher Endstand als endgültig in der Antwort
    # (`hasEnded: true` samt Zwischenstand von vorhin).
    #
    # Und das ist nicht der Randfall, sondern der Normalfall: `added_at` ist der
    # Zeitpunkt der EINGABE, nicht der Spielzeit. Wird ein Bericht nach dem
    # Schlusspfiff in einem Zug getippt, sind sämtliche Ereignisse frisch, die
    # Liste fällt komplett weg und aus einem 3:0 wird ein gemeldetes 0:0.
    #
    # Damit verhält sich diese Methode zugleich wie `delay_live_scores` unten,
    # das ebenfalls nur laufende Spiele zurückhält.
    return game if game.ended?

    cutoff = Time.current.to_i - LIVE_DATA_DELAY.to_i
    game.events = (game.events || []).select { |e| e['added_at'].nil? || e['added_at'] < cutoff }
    game
  end

  # Entfernt Ergebnis-Daten für laufende Spiele aus einer Spielplan-Liste.
  # Anders als bei einem einzelnen Spiel steht hier kein Ereignisstrom zur
  # Verfügung, aus dem sich ein Zwischenstand herausrechnen ließe, deshalb
  # entfällt das Ergebnis ganz.
  #
  # Liegt in ApplicationController, weil dieselbe Liste über mehrere Controller
  # ausgeliefert wird (Liga-Spielplan, Team-Spiele). Ein Controller, der
  # `schedule_item` öffentlich ausgibt und diese Methode NICHT aufruft, ist eine
  # Lücke in der Verzögerung.
  def delay_live_scores(schedule)
    return schedule unless delay_live_data?

    schedule.map do |game|
      next game unless running_entry?(game)

      game.merge(result: nil, result_string: nil)
    end
  end

  # Läuft gerade, aus Sicht einer Spielplan-Zeile.
  #
  # Bewusst `started && !ended` und nicht `state == 'running'`: Game#state
  # liefert :running nur mit gesetztem `record_created_at` und sonst :no_record,
  # während Game#schedule_item das Ergebnis schon an `started?` allein hängt.
  # Ein begonnenes Spiel ohne angelegten Bericht rutschte damit samt Live-Stand
  # durch die Verzögerung. Dieselbe Bedingung nutzt Game#ticker_hash für
  # `isLive`.
  #
  # Die Schlüssel werden zusätzlich als String geprüft. Mit den heute
  # eingesetzten Stores greift das nie: :memory_store serialisiert über DupCoder
  # und gibt Symbole zurück, und selbst Marshal führte Symbole als Symbole
  # zurück. Die Absicherung gilt einem Store mit JSON-Kodierung (Redis,
  # Memcached), der Strings lieferte – ohne sie fiele die Verzögerung dann still
  # aus, ohne Fehler.
  def running_entry?(entry)
    started = entry.fetch(:started) { entry['started'] }
    ended = entry.fetch(:ended) { entry['ended'] }

    started && !ended
  end

  # Zählt jeden mit API-Key beantworteten Zugriff pro Tag und Endpunkt. Eine
  # Stelle deckt damit alle öffentlichen Endpunkte ab, weil
  # @authenticated_api_key ausschließlich in authenticate_public_request gesetzt
  # wird.
  #
  # Nicht gezählt werden Zugriffe per Cookie-Session (dort bleibt die Variable
  # leer) und abgewiesene Requests: Hält eine before_action die Kette an (401
  # wegen fehlendem Key, 429 durch Rack::Attack), läuft diese after_action nicht.
  def track_api_key_usage
    return unless api_key_request?

    ApiKeyUsage.increment!(api_key_id: @authenticated_api_key.id,
                           endpoint: "#{controller_name}##{action_name}")
  end

  def current_user
    user_id = cookies.signed[:user_id]
    return unless user_id

    user = User.find_by_id(user_id)
    # Archivierte Konten gelten als nicht angemeldet – auch eine noch gültige
    # Cookie-Session (bis 7 Tage) endet damit sofort per 401 (Frontend loggt aus).
    user unless user&.archived?
  end

  def save_current_user
    User.current_user = current_user
  end

  # Serverseitige Prüfung für Bild-Uploads (Vereins-, Team- und Verbandslogos sowie Banner).
  # Gibt eine erklärende Fehlermeldung zurück oder nil, wenn die Datei zulässig ist.
  # Nur Raster-Formate: SVG ist bewusst ausgeschlossen, weil ActiveStorage SVG als
  # Binary/Attachment ausliefert (Logos würden nicht als <img> rendern) und ein
  # nicht bereinigtes SVG bei Inline-Auslieferung ein Stored-XSS-Vektor wäre.
  LOGO_ALLOWED_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
  # Dieselbe Zusage, geprüft am Dateiinhalt statt an der Angabe des Browsers:
  # die vips-Loader, die zu den drei erlaubten Formaten gehören. spngload ist die
  # libspng-Variante von pngload und steht im aktuellen Abbild nicht zur
  # Verfügung; sie ist mit aufgeführt, damit ein neu gebautes Abbild nicht
  # plötzlich jedes PNG abweist.
  LOGO_ALLOWED_VIPS_LOADERS = %w[pngload spngload jpegload webpload].freeze
  LOGO_MAX_SIZE = 3.megabytes
  # Werbebanner (Liga, Spielbetrieb, Landesverband) teilen sich eine Grenze: Sie
  # werden auf jeder Seite des jeweiligen Bereichs mitgeladen und bleiben deshalb
  # deutlich kleiner als ein Logo.
  BANNER_MAX_SIZE = 500.kilobytes

  # square: Vereins- und Teamlogos werden in quadratischen Kacheln und Tabellenzeilen
  # ausgespielt und müssen deshalb quadratisch geliefert werden. Verbandslogos und
  # Banner laufen dagegen über die Breite und sind fast immer Wortmarken im
  # Querformat; ein Quadrat-Zwang würde dort jede reale Vorlage abweisen.
  def logo_upload_error(file, square: true, max_size: LOGO_MAX_SIZE)
    # Kein hochgeladenes File (z. B. String-Parameter): sauber als 422 abweisen,
    # statt bei file.content_type mit NoMethodError (500) abzubrechen.
    return 'Ungültige Bilddatei.' unless file.respond_to?(:content_type) && file.respond_to?(:tempfile)

    # content_type ist die Angabe aus dem Multipart-Kopf, also das, was der
    # hochladende Browser behauptet. Sie wird zuerst geprüft, weil sie ohne
    # Dateizugriff auskommt; verlassen kann man sich darauf nicht (s. unten).
    unless LOGO_ALLOWED_CONTENT_TYPES.include?(file.content_type)
      return 'Ungültiges Dateiformat. Erlaubt sind PNG, JPG oder WebP.'
    end

    if file.size > max_size
      # number_to_human_size statt Division durch 1.megabyte: Das Bannerlimit liegt
      # unter einem Megabyte und wäre sonst als "Maximal 0 MB erlaubt" gemeldet worden.
      return "Die Datei ist zu groß. Maximal #{ActiveSupport::NumberHelper.number_to_human_size(max_size)} erlaubt."
    end

    require 'vips'
    begin
      image = Vips::Image.new_from_file(file.tempfile.path)
      # Der eigentliche Formatriegel: Welcher Loader gegriffen hat, weiß vips aus
      # dem Dateiinhalt. Eine als image/png deklarierte SVG kam über die
      # Kopfzeilen-Prüfung hinweg, wurde von vips anstandslos gelesen (also auch
      # nicht vom Bild-Check abgewiesen) und landete in der Ablage, wo
      # ActiveStorage ihren Typ selbst neu bestimmte. Gefragt wird dieselbe
      # Instanz, die die Datei tatsächlich dekodiert; Kopfzeile und Inhalt können
      # damit nicht auseinanderlaufen.
      loader = image.get('vips-loader')
    rescue Vips::Error
      return 'Die Datei konnte nicht als Bild gelesen werden.'
    end

    # Eigene Meldung, nicht dieselbe wie bei der Kopfzeilen-Prüfung: Browser
    # leiten den Multipart-Typ aus der DATEIENDUNG ab. Wer ein GIF in "logo.png"
    # umbenennt, kommt an der ersten Prüfung vorbei und bekäme hier "Erlaubt sind
    # PNG, JPG oder WebP" zu lesen, also genau das Format, das seine Datei zu
    # sein vorgibt. Der Hinweis muss sagen, dass der INHALT nicht dazu passt,
    # sonst sucht man den Fehler am falschen Ende.
    #
    # Ein Format, das sich nicht benennen lässt, gehört ebenfalls nicht in die
    # Ablage: Sollte vips das Feld nicht gesetzt haben, wirft get und der Aufruf
    # endet oben mit der Lesemeldung, statt die Prüfung zu überspringen.
    unless LOGO_ALLOWED_VIPS_LOADERS.include?(loader)
      return 'Der Inhalt der Datei passt nicht zur Dateiendung. Erlaubt sind echte PNG-, JPG- oder WebP-Bilder.'
    end

    return 'Das Logo muss quadratisch sein (gleiche Breite und Höhe).' if square && image.width != image.height

    nil
  end
end
