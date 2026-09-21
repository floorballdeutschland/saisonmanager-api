require 'test_helper'

# Der gespeicherte Zugang ist ein Geheimnis, und die Staging-Umgebung traegt
# einen 1:1-Klon dieser Tabelle. Entsprechend steht zu jedem Lesepfad die
# Gegenprobe, wann NICHTS herauskommt.
class StreamCredentialTest < ActiveSupport::TestCase
  SCHLUESSEL = 'ein-hinreichend-langer-testschluessel'.freeze

  test 'der Token kommt verschluesselt in die Spalte und unveraendert zurueck' do
    mit_schluessel(SCHLUESSEL) do
      satz = StreamCredential.create!(refresh_token: '1//0-refresh')

      assert_equal '1//0-refresh', satz.reload.refresh_token
      # Nicht im Klartext: Ein Datenbankabzug wandert nach Staging und in
      # Sicherungen.
      assert_not_includes satz.refresh_token_ciphertext, '1//0-refresh'
    end
  end

  # DER FALL STAGING: Dort fehlt YOUTUBE_TOKEN_KEY, der Klon traegt die Zeile
  # aber mit. Ohne diesen Riegel beendete eine Testumgebung echte
  # Uebertragungen des Verbandskanals.
  test 'GEGENPROBE: ohne Schluessel ist der Token nicht lesbar' do
    satz = mit_schluessel(SCHLUESSEL) { StreamCredential.create!(refresh_token: '1//0-refresh') }

    ohne_schluessel do
      assert_nil satz.reload.refresh_token
      assert_not satz.connected?
      assert_nil StreamCredential.credentials
    end
  end

  test 'GEGENPROBE: ein anderer Schluessel liefert nil statt einer Ausnahme' do
    satz = mit_schluessel(SCHLUESSEL) { StreamCredential.create!(refresh_token: '1//0-refresh') }

    mit_schluessel('ein-voellig-anderer-schluessel') do
      assert_nil satz.reload.refresh_token
    end
  end

  # Ein unlesbar gewordener Zugang muss loeschbar bleiben, sonst bliebe er
  # fuer immer stehen.
  test 'leeren geht auch ohne Schluessel' do
    satz = mit_schluessel(SCHLUESSEL) { StreamCredential.create!(refresh_token: '1//0-refresh') }

    ohne_schluessel do
      satz.update!(refresh_token: nil)

      assert_nil satz.reload.refresh_token_ciphertext
    end
  end

  test 'credentials traegt das Client-Paar aus der Umgebung' do
    mit_schluessel(SCHLUESSEL) do
      StreamCredential.create!(refresh_token: '1//0-refresh')

      mit_client do
        werte = StreamCredential.credentials

        assert_equal '1//0-refresh', werte[:refresh_token]
        assert_equal 'db', werte[:source]
      end
    end
  end

  # Wird die Kennung in der Google Cloud getauscht, passt der gespeicherte Token
  # nicht mehr. Lieber „nicht verbunden" melden als beim naechsten Lauf des
  # Waechters an `invalid_grant` scheitern.
  test 'GEGENPROBE: eine andere Client-Kennung entwertet den gespeicherten Zugang' do
    mit_schluessel(SCHLUESSEL) do
      StreamCredential.create!(refresh_token: '1//0-refresh', client_id: 'web-client')

      mit_client('inzwischen-anderer-client') do
        assert_nil StreamCredential.credentials
      end
    end
  end

  # Der Token allein nuetzt nichts: Google erneuert ihn nur gegen das Paar, mit
  # dem er ausgegeben wurde.
  test 'GEGENPROBE: ohne Client-Paar keine credentials' do
    mit_schluessel(SCHLUESSEL) do
      StreamCredential.create!(refresh_token: '1//0-refresh')

      ohne_client { assert_nil StreamCredential.credentials }
    end
  end

  private

  def mit_schluessel(wert)
    vorher = ENV.fetch('YOUTUBE_TOKEN_KEY', nil)
    ENV['YOUTUBE_TOKEN_KEY'] = wert
    yield
  ensure
    vorher.nil? ? ENV.delete('YOUTUBE_TOKEN_KEY') : ENV['YOUTUBE_TOKEN_KEY'] = vorher
  end

  def ohne_schluessel
    vorher = ENV.fetch('YOUTUBE_TOKEN_KEY', nil)
    ENV.delete('YOUTUBE_TOKEN_KEY')
    yield
  ensure
    ENV['YOUTUBE_TOKEN_KEY'] = vorher unless vorher.nil?
  end

  # DAS WEB-PAAR: Gegen dieses Paar wird der gespeicherte Token erneuert, denn
  # von ihm stammt er. Das Desktop-Paar gehoert zum alten Weg ueber die
  # Umgebungsvariablen.
  # Sichern und zuruecklegen, nicht loeschen -- sonst fehlen die Variablen dem
  # Rest des Laufs, und spaetere Pruefsaetze kippen je nach Dateireihenfolge.
  def mit_client(kennung = 'web-client')
    vorher = %w[YOUTUBE_WEB_CLIENT_ID YOUTUBE_WEB_CLIENT_SECRET].index_with { |k| ENV.fetch(k, nil) }
    ENV['YOUTUBE_WEB_CLIENT_ID'] = kennung
    ENV['YOUTUBE_WEB_CLIENT_SECRET'] = 'web-geheim'
    yield
  ensure
    vorher.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def ohne_client
    vorher = %w[YOUTUBE_WEB_CLIENT_ID YOUTUBE_WEB_CLIENT_SECRET].index_with { |k| ENV.fetch(k, nil) }
    vorher.each_key { |k| ENV.delete(k) }
    yield
  ensure
    vorher.each { |k, v| ENV[k] = v unless v.nil? }
  end
end
