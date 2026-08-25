require 'test_helper'

# Der Lizenzlisten-Link hing früher am Versandzeitpunkt (72 h ab Veröffentlichen
# der Ansetzung) und war bei einer Ansetzung Wochen vor dem Spiel längst
# abgelaufen. Jetzt hängt die Gültigkeit am Spiel: Ende des Tages NACH dem Spiel.
class LicenseListLinkTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @game_day = create(:game_day, date: '2026-03-07')
    @game = create(:game, game_day: @game_day, start_time: '14:00')
  end

  test 'Gueltigkeit endet am Ende des Tages nach dem Spiel' do
    expires_at = LicenseListLink.new(@game).expires_at

    assert_equal Date.new(2026, 3, 8), expires_at.to_date
    assert_equal 23, expires_at.hour
    assert_equal 59, expires_at.min
    # Kalender des Spielbetriebs, nicht der der Anwendung (UTC).
    assert_equal 'Europe/Berlin', expires_at.time_zone.name
  end

  test 'Link steht bis zum Tag nach dem Spiel' do
    travel_to Time.utc(2026, 3, 8, 12, 0) do
      assert LicenseListLink.new(@game).available?
      assert_includes LicenseListLink.new(@game).url, '/lizenzliste?token='
    end
  end

  test 'nach Ablauf gibt es keinen Link mehr' do
    travel_to Time.utc(2026, 3, 9, 12, 0) do
      link = LicenseListLink.new(@game)

      assert_not link.available?
      assert_nil link.url
    end
  end

  # `game_days.date` ist eine Textspalte; im Altbestand stehen unlesbare Werte.
  # Ohne Datum gibt es keine spielbezogene Gültigkeit – und keinen Link, statt
  # eines Absturzes mitten im Mailversand.
  test 'ohne lesbares Spieltagsdatum gibt es keinen Link' do
    @game_day.update_column(:date, 'unbekannt')

    link = LicenseListLink.new(@game.reload)

    assert_nil link.expires_at
    assert_not link.available?
    assert_nil link.url
  end

  test 'das Token verweist auf das Spiel und laeuft mit expires_at ab' do
    travel_to Time.utc(2026, 3, 6, 12, 0) do
      url = LicenseListLink.new(@game).url
      token = CGI.unescape(url.split('token=').last)

      payload = Rails.application.message_verifier('license_list').verified(token)

      assert_equal @game.id, payload[:game_id]
    end

    # Ein am Tag vor dem Spiel erzeugtes Token ist zwei Tage später wertlos.
    url = travel_to(Time.utc(2026, 3, 6, 12, 0)) { LicenseListLink.new(@game).url }
    token = CGI.unescape(url.split('token=').last)
    travel_to Time.utc(2026, 3, 9, 12, 0) do
      assert_nil Rails.application.message_verifier('license_list').verified(token)
    end
  end
end
