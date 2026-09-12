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
