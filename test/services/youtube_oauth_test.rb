require 'test_helper'

# Geprueft wird, WAS mit der Antwort von Google geschieht -- nicht, ob Net::HTTP
# funktioniert. Die beiden HTTP-Wege werden deshalb ersetzt.
class YoutubeOauthTest < ActiveSupport::TestCase
  setup do
    @vorher = umgebung_sichern
    ENV['YOUTUBE_WEB_CLIENT_ID'] = 'web-client'
    ENV['YOUTUBE_WEB_CLIENT_SECRET'] = 'web-geheim'
    ENV['YOUTUBE_TOKEN_KEY'] = 'ein-hinreichend-langer-testschluessel'
  end

  teardown { umgebung_zurueck(@vorher) }

  test 'der eingeloeste Code landet verschluesselt als Zugang' do
    nutzer = create(:user, :admin)
    dienst = dienst_mit(token: { 'refresh_token' => '1//0-neu', 'access_token' => 'zugriff',
                                 'scope' => 'https://www.googleapis.com/auth/youtube.force-ssl' })

    satz = dienst.verbinden!(user: nutzer)

    assert_equal '1//0-neu', satz.reload.refresh_token
    assert_equal 'floorball deutschland', satz.channel_title
    assert_equal nutzer.id, satz.connected_by_user_id
    assert satz.connected_at
  end

  test 'ein zweites Verbinden ersetzt den vorhandenen Zugang, statt einen zweiten anzulegen' do
    StreamCredential.create!(refresh_token: '1//0-alt')
    dienst = dienst_mit(token: { 'refresh_token' => '1//0-neu', 'access_token' => 'zugriff' })

    dienst.verbinden!

    assert_equal 1, StreamCredential.count
    assert_equal '1//0-neu', StreamCredential.current.refresh_token
  end

  # Ohne Refresh-Token ist nichts gewonnen: Der Waechter laeuft unbeaufsichtigt
  # und kann sich nicht anmelden.
  test 'GEGENPROBE: ohne Refresh-Token wird nichts gespeichert' do
    dienst = dienst_mit(token: { 'access_token' => 'zugriff' })

    assert_raises(YoutubeOauth::NoRefreshToken) { dienst.verbinden! }
    assert_equal 0, StreamCredential.count
  end

  # Der Fall, der beim Einrichten eine Stunde gekostet hat: Am Konto haengen
  # zwei gleichnamige Kanaele, und der leere kann nicht senden.
  #
  # ERSETZT WIRD HIER NUR DER HTTP-WEG, nicht die Erkennung: Die Antwort ist die
  # echte von Google, und `rohtext` und der rescue-Zweig laufen mit. Wuerde der
  # Test `live_pruefen` selbst wegstubben, bliebe er gruen, waehrend der Riegel
  # ins Leere greift -- und gespeichert wuerde ein Kanal, der nicht senden kann.
  test 'GEGENPROBE: ein Kanal ohne Livestreaming wird nicht gespeichert' do
    dienst = YoutubeOauth.new(code: 'code-1', redirect_uri: 'postmessage')
    dienst.define_singleton_method(:token_abruf) do |_ziel|
      { 'refresh_token' => '1//0-neu', 'access_token' => 'zugriff' }
    end
    dienst.define_singleton_method(:api_get) do |_zugriff, pfad, **_params|
      # Wortlaut der echten Antwort, aufbereitet wie in `rohtext`.
      unless pfad == 'channels'
        raise YoutubeOauth::Error, 'liveStreamingNotEnabled The user is not enabled for live streaming.'
      end

      { 'items' => [{ 'id' => 'UC-leer',
                      'snippet' => { 'title' => 'floorball deutschland' },
                      'statistics' => { 'videoCount' => '0' } }] }
    end

    assert_raises(YoutubeOauth::LiveStreamingDisabled) { dienst.verbinden! }
    assert_equal 0, StreamCredential.count
  end

  # Ein Fehler, der NICHT am Livestreaming liegt, darf nicht als der eine
  # bekannte Fall durchgehen -- sonst schickte die Oberflaeche jeden Ausfall
  # mit dem Hinweis auf den falschen Kanal weg.
  test 'GEGENPROBE: ein anderer API-Fehler bleibt ein gewoehnlicher Fehler' do
    dienst = YoutubeOauth.new(code: 'code-1', redirect_uri: 'postmessage')
    dienst.define_singleton_method(:token_abruf) do |_ziel|
      { 'refresh_token' => '1//0-neu', 'access_token' => 'zugriff' }
    end
    dienst.define_singleton_method(:api_get) do |_zugriff, pfad, **_params|
      raise YoutubeOauth::Error, 'backendError Internal error' unless pfad == 'channels'

      { 'items' => [{ 'id' => 'UC-echt', 'snippet' => { 'title' => 'floorball deutschland' } }] }
    end

    fehler = assert_raises(YoutubeOauth::Error) { dienst.verbinden! }

    assert_not_kind_of YoutubeOauth::LiveStreamingDisabled, fehler
    assert_equal 0, StreamCredential.count
  end

  # Der Token gehoert dem WEB-Client. Ohne die gespeicherte Kennung liesse sich
  # nicht pruefen, ob er noch zu dem Paar passt, gegen das erneuert wird.
  test 'die Kennung des Web-Clients wird mitgeschrieben' do
    satz = dienst_mit(token: { 'refresh_token' => '1//0-neu', 'access_token' => 'zugriff' })
           .verbinden!

    assert_equal 'web-client', satz.client_id
  end

  # Im Aufklappfenster setzt Google die Umleitungsadresse selbst. Passt der erste
  # Wert nicht, muss der zweite versucht werden -- sonst haenge die Verbindung an
  # einer Version der Google-Bibliothek.
  test 'bei redirect_uri_mismatch wird postmessage nachgesetzt' do
    versuche = []
    dienst = YoutubeOauth.new(code: 'code-1', redirect_uri: 'https://saisonmanager.org')
    dienst.define_singleton_method(:token_abruf) do |ziel|
      versuche << ziel
      next { 'error' => 'redirect_uri_mismatch' } if ziel != 'postmessage'

      { 'refresh_token' => '1//0-neu', 'access_token' => 'zugriff' }
    end
    stumme_pruefungen(dienst)

    dienst.verbinden!

    assert_equal ['https://saisonmanager.org', 'postmessage'], versuche
    assert_equal '1//0-neu', StreamCredential.current.refresh_token
  end

  # Ein anderer Fehler ist kein Adressproblem. Ein zweiter Anlauf verbrennt nur
  # Zeit und verdeckt den Grund.
  test 'GEGENPROBE: ein anderer Fehler loest keinen zweiten Anlauf aus' do
    versuche = []
    dienst = YoutubeOauth.new(code: 'code-1', redirect_uri: 'https://saisonmanager.org')
    dienst.define_singleton_method(:token_abruf) do |ziel|
      versuche << ziel
      { 'error' => 'invalid_grant', 'error_description' => 'Bad Request' }
    end
    stumme_pruefungen(dienst)

    fehler = assert_raises(YoutubeOauth::Error) { dienst.verbinden! }

    assert_equal 1, versuche.size
    assert_includes fehler.message, 'invalid_grant'
  end

  test 'ohne eingerichteten Weg meldet configured? false' do
    ENV.delete('YOUTUBE_WEB_CLIENT_SECRET')

    assert_not YoutubeOauth.configured?
    assert_includes YoutubeOauth.fehlende_einstellungen, 'YOUTUBE_WEB_CLIENT_SECRET'
  end

  private

  def dienst_mit(token:, live_fehler: nil)
    dienst = YoutubeOauth.new(code: 'code-1', redirect_uri: 'postmessage')
    dienst.define_singleton_method(:token_abruf) { |_ziel| token }
    stumme_pruefungen(dienst, live_fehler: live_fehler)
    dienst
  end

  def stumme_pruefungen(dienst, live_fehler: nil)
    dienst.define_singleton_method(:kanal_lesen) do |_zugriff|
      { id: 'UC-echt', title: 'floorball deutschland', videos: '412' }
    end
    dienst.define_singleton_method(:live_pruefen) do |_zugriff|
      raise YoutubeOauth::LiveStreamingDisabled if live_fehler

      {}
    end
  end

  def umgebung_sichern
    %w[YOUTUBE_WEB_CLIENT_ID YOUTUBE_WEB_CLIENT_SECRET YOUTUBE_TOKEN_KEY]
      .index_with { |key| ENV.fetch(key, nil) }
  end

  def umgebung_zurueck(werte)
    werte.each { |key, wert| wert.nil? ? ENV.delete(key) : ENV[key] = wert }
  end
end
