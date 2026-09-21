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
  test 'GEGENPROBE: ein Kanal ohne Livestreaming wird nicht gespeichert' do
    dienst = dienst_mit(token: { 'refresh_token' => '1//0-neu', 'access_token' => 'zugriff' },
                        live_fehler: YoutubeOauth::Error.new('liveStreamingNotEnabled Not enabled'))

    assert_raises(YoutubeOauth::LiveStreamingDisabled) { dienst.verbinden! }
    assert_equal 0, StreamCredential.count
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
