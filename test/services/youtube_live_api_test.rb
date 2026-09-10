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

  private

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
