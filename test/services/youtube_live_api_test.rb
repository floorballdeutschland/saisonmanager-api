require 'test_helper'

class YoutubeLiveApiTest < ActiveSupport::TestCase
  # Der fehlende Zugang ist der Normalzustand in Entwicklung und auf Staging:
  # Dort soll niemand den Produktionskanal beenden können. Er muss deshalb
  # sauber erkennbar sein und nicht erst beim ersten HTTP-Aufruf auffallen.
  test 'ohne Umgebungsvariablen ist der Zugang nicht eingerichtet' do
    ohne_env do
      assert_not YoutubeLiveApi.configured?
    end
  end

  test 'benennt die fehlenden Variablen statt nur zu scheitern' do
    ohne_env do
      fehler = assert_raises(YoutubeLiveApi::NotConfigured) { YoutubeLiveApi.new }
      assert_match(/YOUTUBE_CLIENT_ID/, fehler.message)
      assert_match(/YOUTUBE_REFRESH_TOKEN/, fehler.message)
    end
  end

  test 'mit allen drei Variablen ist der Zugang eingerichtet' do
    mit_env do
      assert YoutubeLiveApi.configured?
      assert_nothing_raised { YoutubeLiveApi.new }
    end
  end

  # Eine halb gesetzte Konfiguration ist der gefährlichere Fall: Sie sieht
  # eingerichtet aus und scheitert erst beim Zugriff.
  test 'zwei von drei Variablen genuegen nicht' do
    ohne_env do
      ENV['YOUTUBE_CLIENT_ID'] = 'id'
      ENV['YOUTUBE_CLIENT_SECRET'] = 'secret'
      assert_not YoutubeLiveApi.configured?
    end
  end

  # --- Freischalten nach dem Spiel -------------------------------------------
  #
  # Ein `update` ERSETZT den angegebenen Teil der Ressource: Was im Koerper
  # fehlt, ist danach weg. Deshalb wird erst gelesen. Diese Tests halten das
  # fest, denn der Schaden waere unsichtbar -- die Uebertragung stuende
  # oeffentlich, aber ohne ihre Pflichtangaben.

  test 'schickt den gelesenen Status zurueck und aendert nur die Sichtbarkeit' do
    gesendet = []
    api = api_mit(
      { 'items' => [{ 'id' => 'bc-1',
                      'status' => { 'privacyStatus' => 'unlisted',
                                    'selfDeclaredMadeForKids' => false } }] },
      gesendet
    )

    assert_equal :veroeffentlicht, api.publish!('bc-1')
    assert_equal 1, gesendet.size
    _pfad, koerper, params = gesendet.first
    assert_equal 'public', koerper[:status]['privacyStatus']
    assert_equal false, koerper[:status]['selfDeclaredMadeForKids'],
                 'die Pflichtangabe des Kanals darf nicht verlorengehen'
    assert_equal 'id,status', params[:part]
  end

  test 'eine bereits oeffentliche Uebertragung wird nicht angefasst' do
    gesendet = []
    api = api_mit({ 'items' => [{ 'id' => 'bc-1', 'status' => { 'privacyStatus' => 'public' } }] }, gesendet)

    assert_equal :schon_oeffentlich, api.publish!('bc-1')
    assert_empty gesendet
  end

  # "private" ist der naheliegendste Weg, eine Aufzeichnung zurueckzuziehen.
  # Der Cronjob darf das nicht drei Stunden spaeter wieder aufdrehen.
  test 'eine zurueckgezogene Uebertragung bleibt zurueckgezogen' do
    gesendet = []
    api = api_mit({ 'items' => [{ 'id' => 'bc-1', 'status' => { 'privacyStatus' => 'private' } }] }, gesendet)

    assert_equal :zurueckgezogen, api.publish!('bc-1')
    assert_empty gesendet
  end

  test 'ohne Eintrag gilt die Uebertragung als verschwunden' do
    gesendet = []
    api = api_mit({ 'items' => [] }, gesendet)

    assert_equal :verschwunden, api.publish!('bc-1')
    assert_empty gesendet
  end

  # Blind zu schreiben hiesse, genau die Angaben zu loeschen, wegen derer
  # ueberhaupt gelesen wird.
  test 'ohne gelesenen Status wird nicht geschrieben' do
    gesendet = []
    api = api_mit({ 'items' => [{ 'id' => 'bc-1' }] }, gesendet)

    assert_raises(YoutubeLiveApi::Error) { api.publish!('bc-1') }
    assert_empty gesendet
  end

  # --- Sprungmarken in der Beschreibung (api#815) ----------------------------

  test 'Videodaten: Start aus liveStreamingDetails, Laenge aus contentDetails' do
    items = [
      { 'id' => 'bc-1',
        'liveStreamingDetails' => { 'actualStartTime' => '2026-10-11T15:50:00Z',
                                    'actualEndTime' => '2026-10-11T19:00:00Z' },
        'contentDetails' => { 'duration' => 'PT2H3M4S' } },
      { 'id' => 'bc-2', 'contentDetails' => { 'duration' => 'P0D' } }
    ]
    api = api_mit({ 'items' => items }, [])

    details = api.videos(%w[bc-1 bc-2])

    assert_equal Time.utc(2026, 10, 11, 15, 50), details['bc-1'][:actual_start_at]
    assert_equal 7384, details['bc-1'][:duration_seconds], 'nicht actualEndTime'
    assert_nil details['bc-2'][:duration_seconds], 'P0D heisst: noch in Verarbeitung'
  end

  # Dieselbe Falle wie bei publish!: `videos.update` ersetzt den snippet.
  test 'Beschreibung: schickt Titel, Kategorie und Schlagwoerter mit, nur die Beschreibung ist neu' do
    gesendet = []
    api = api_mit({ 'items' => [{ 'id' => 'bc-1',
                                  'snippet' => { 'title' => 'Heim vs Gast', 'categoryId' => '17',
                                                 'description' => 'alt', 'tags' => ['Floorball'],
                                                 'channelId' => 'UCxyz', 'publishedAt' => '2026-10-11' } }] },
                  gesendet)

    assert_equal :geschrieben, api.update_description!('bc-1') { |alt| "#{alt}\nneu" }
    pfad, koerper, params = gesendet.first
    assert_equal 'videos', pfad
    assert_equal 'snippet', params[:part]
    assert_equal({ 'title' => 'Heim vs Gast', 'categoryId' => '17', 'description' => "alt\nneu",
                   'tags' => ['Floorball'] }, koerper[:snippet])
  end

  test 'Beschreibung: unveraendert wird nicht geschrieben' do
    gesendet = []
    api = api_mit({ 'items' => [{ 'id' => 'bc-1', 'snippet' => { 'title' => 'T', 'categoryId' => '17',
                                                                   'description' => 'gleich' } }] }, gesendet)

    assert_equal :unveraendert, api.update_description!('bc-1') { |alt| alt }
    assert_empty gesendet
  end

  test 'Beschreibung: ohne Titel oder Kategorie wird nicht geschrieben' do
    gesendet = []
    api = api_mit({ 'items' => [{ 'id' => 'bc-1', 'snippet' => { 'description' => 'x' } }] }, gesendet)

    assert_raises(YoutubeLiveApi::Error) { api.update_description!('bc-1') { |alt| "#{alt}!" } }
    assert_empty gesendet
  end

  test 'Beschreibung: geloeschtes Video ist verschwunden' do
    api = api_mit({ 'items' => [] }, [])

    assert_equal :verschwunden, api.update_description!('bc-1') { |alt| alt }
  end

  # Der ueber die Oberflaeche verbundene Zugang schlaegt die Umgebung. Sonst
  # bliebe ein abgelaufener Token in der `.env` fuer immer der massgebliche, und
  # jedes Neuverbinden waere wirkungslos, ohne dass es jemand sieht.
  test 'der gespeicherte Zugang hat Vorrang vor den Umgebungsvariablen' do
    mit_env do
      mit_token_schluessel do
        mit_web_client do
          StreamCredential.create!(refresh_token: '1//0-aus-der-oberflaeche', client_id: 'web-client')

          assert_equal 'db', YoutubeLiveApi.source
          zugang = YoutubeLiveApi.credentials
          assert_equal '1//0-aus-der-oberflaeche', zugang[:refresh_token]
          # Erneuert wird gegen den Client, der den Token ausgegeben hat.
          assert_equal 'web-client', zugang[:client_id]
        end
      end
    end
  end

  test 'ohne gespeicherten Zugang zaehlen die Umgebungsvariablen' do
    mit_env do
      assert YoutubeLiveApi.configured?
      assert_equal 'env', YoutubeLiveApi.source
    end
  end

  test 'GEGENPROBE: ohne beides ist nichts eingerichtet' do
    ohne_env do
      assert_not YoutubeLiveApi.configured?
      assert_nil YoutubeLiveApi.source
    end
  end

  private

  # Ersetzt die beiden HTTP-Wege, nicht die Logik darueber: Geprueft wird, WAS
  # geschickt wird, nicht ob Net::HTTP funktioniert.
  def api_mit(antwort, gesendet)
    api = nil
    mit_env { api = YoutubeLiveApi.new }
    api.define_singleton_method(:get) { |*_args, **_kwargs| antwort }
    api.define_singleton_method(:put_json) do |pfad, koerper, **params|
      gesendet << [pfad, koerper, params]
      {}
    end
    api
  end

  # Sichern und zuruecklegen, nicht loeschen: Auf einem Container, auf dem die
  # Variablen gesetzt sind, naehme das Loeschen sie dem REST des Laufs weg, und
  # spaetere Pruefsaetze kippten je nach Dateireihenfolge.
  def mit_web_client
    vorher = %w[YOUTUBE_WEB_CLIENT_ID YOUTUBE_WEB_CLIENT_SECRET].index_with { |k| ENV.fetch(k, nil) }
    ENV['YOUTUBE_WEB_CLIENT_ID'] = 'web-client'
    ENV['YOUTUBE_WEB_CLIENT_SECRET'] = 'web-geheim'
    yield
  ensure
    vorher.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def mit_token_schluessel
    vorher = ENV.fetch('YOUTUBE_TOKEN_KEY', nil)
    ENV['YOUTUBE_TOKEN_KEY'] = 'ein-hinreichend-langer-testschluessel'
    yield
  ensure
    vorher.nil? ? ENV.delete('YOUTUBE_TOKEN_KEY') : ENV['YOUTUBE_TOKEN_KEY'] = vorher
  end

  def ohne_env
    vorher = YoutubeLiveApi::ENV_KEYS.index_with { |key| ENV.fetch(key, nil) }
    YoutubeLiveApi::ENV_KEYS.each { |key| ENV.delete(key) }
    yield
  ensure
    vorher.each { |key, wert| wert.nil? ? ENV.delete(key) : ENV[key] = wert }
  end

  def mit_env
    ohne_env do
      YoutubeLiveApi::ENV_KEYS.each { |key| ENV[key] = "wert-#{key}" }
      yield
    end
  end
end
