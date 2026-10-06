require 'test_helper'

# Gültigkeitsfenster der Zugangslinks (GameDayLinkWindow): 72 Stunden vor dem
# Spieltag bis Ende des Folgetags, deutscher Kalender. Anlass Feedback #70: Ein
# vorab ausgedruckter Zugang war am Spieltag schon abgelaufen.
class GameDayLinkWindowTest < ActiveSupport::TestCase
  setup do
    @user = create(:user, :admin)
    # 05.03.2026, 11:00 deutscher Zeit (MEZ, +1).
    travel_to Time.utc(2026, 3, 5, 10, 0)
    @game_day = create(:game_day, date: '2026-03-20')
  end

  teardown { travel_back }

  test 'ein früh erzeugter Sekretariatslink gilt von 72 h vor dem Spieltag bis Ende des Folgetags' do
    link, = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    # 20.03. 00:00 MEZ minus 72 h = 16.03. 23:00 UTC
    assert_equal Time.utc(2026, 3, 16, 23, 0), link.valid_from
    # 21.03. 23:59:59 MEZ = 22:59:59 UTC
    assert_equal Time.utc(2026, 3, 21, 22, 59, 59), link.expires_at.change(usec: 0)
  end

  test 'vor dem Fenster berechtigt das Token zu nichts, danach schon' do
    link, raw_token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    assert_nil GameDaySecretaryLink.find_by_token(raw_token)
    assert_equal link, GameDaySecretaryLink.find_unexpired_by_token(raw_token)

    travel_to Time.utc(2026, 3, 16, 23, 1)
    assert_equal link, GameDaySecretaryLink.find_by_token(raw_token)

    travel_to Time.utc(2026, 3, 21, 23, 1)
    assert_nil GameDaySecretaryLink.find_by_token(raw_token)
  end

  # Der Code wird eingelöst, damit das Sekretariat „gilt erst ab" lesen kann
  # statt „ungültig". Berechtigen darf der Token trotzdem erst im Fenster.
  test 'redeem nimmt einen noch nicht begonnenen Code an, der Token trägt aber noch nicht' do
    link, _token, raw_code = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    redeemed, redeemed_token = GameDaySecretaryLink.redeem(raw_code)

    assert_equal link, redeemed
    assert_not redeemed.started?
    assert_nil GameDaySecretaryLink.find_by_token(redeemed_token)
  end

  test 'ein Link über mehrere Spieltage reicht vom frühesten bis zum spätesten' do
    later = create(:game_day, date: '2026-03-22')

    link, = GameDaySecretaryLink.generate!(game_days: [later, @game_day], created_by: @user)

    assert_equal Time.utc(2026, 3, 16, 23, 0), link.valid_from
    assert_equal Time.utc(2026, 3, 23, 22, 59, 59), link.expires_at.change(usec: 0)
  end

  # Bericht nachtragen: Wer den Zugang erst nach dem Spieltag erzeugt, darf
  # keinen Link bekommen, der schon beim Erzeugen abgelaufen ist.
  test 'nach dem Spieltag erzeugt gilt die bisherige Mindestdauer ab Ausgabe' do
    past = create(:game_day, date: '2026-03-02')

    link, raw_token = GameDaySecretaryLink.generate!(game_days: [past], created_by: @user)

    assert_equal Time.current + GameDaySecretaryLink::VALIDITY, link.expires_at
    assert_equal link, GameDaySecretaryLink.find_by_token(raw_token)
  end

  test 'ohne lesbares Datum gilt der Link sofort und für die Mindestdauer' do
    undated = create(:game_day, date: nil)

    link, raw_token = GameDayOverlayLink.generate!(game_day: undated, created_by: @user)

    assert_equal Time.current, link.valid_from
    assert_equal Time.current + GameDayOverlayLink::LIFETIME, link.expires_at
    assert_equal link, GameDayOverlayLink.find_by_token(raw_token)
  end

  test 'der Overlay-Zugang hat dasselbe Fenster' do
    link, raw_token = GameDayOverlayLink.generate!(game_day: @game_day, created_by: @user)

    assert_equal Time.utc(2026, 3, 16, 23, 0), link.valid_from
    assert_equal Time.utc(2026, 3, 21, 22, 59, 59), link.expires_at.change(usec: 0)
    assert_nil GameDayOverlayLink.find_by_token(raw_token)
  end

  test 'wird der Spieltag verschoben, ziehen die laufenden Links mit' do
    secretary, = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)
    overlay, = GameDayOverlayLink.generate!(game_day: @game_day, created_by: @user)

    @game_day.update!(date: '2026-03-27')

    # 27.03. 00:00 MEZ minus 72 h = 23.03. 23:00 UTC; Ende 28.03. MEZ
    [secretary, overlay].each do |link|
      link.reload
      assert_equal Time.utc(2026, 3, 23, 23, 0), link.valid_from
      assert_equal Time.utc(2026, 3, 28, 22, 59, 59), link.expires_at.change(usec: 0)
    end
  end

  test 'ein abgelaufener Link lebt durch das Verschieben nicht wieder auf' do
    link, = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)
    link.update!(expires_at: 1.minute.ago)

    @game_day.update!(date: '2026-03-27')

    assert_operator link.reload.expires_at, :<, Time.current
  end

  test 'ein Altbestand ohne Beginn gilt ab Ausgabe' do
    link, raw_token = GameDayOverlayLink.generate!(game_day: @game_day, created_by: @user)
    link.update_columns(valid_from: nil)

    assert_equal link, GameDayOverlayLink.find_by_token(raw_token)
  end
end
