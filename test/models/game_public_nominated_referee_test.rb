require 'test_helper'

# Bis August 2026 stand die Markierung „personenscharf ansetzen" als Sentinel-Text
# 'Ansetzung durch RSK' im Freitextfeld und war damit im öffentlichen Spielplan
# sichtbar. Seit #403 ist sie eine eigene Spalte; der Hinweis muss für Zuschauer
# daraus abgeleitet werden, ohne in die Eingabemaske der SBK zurückzuschlagen.
class GamePublicNominatedRefereeTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    league = create(:league)
    @game_day = create(:game_day, league: league, date: (Date.today + 7).to_s)
  end

  test 'ohne Freitext leitet die oeffentliche Ausgabe den Hinweis aus dem Flag ab' do
    game = create(:game, game_day: @game_day, person_level_assignment: true,
                         nominated_referee_string: '')

    assert_equal 'Ansetzung durch Ansetzer*in', game.public_nominated_referee_string
    assert_equal 'Ansetzung durch Ansetzer*in', game.schedule_item[:nominated_referee_string]
    assert_equal 'Ansetzung durch Ansetzer*in', game.full_hash[:nominated_referees]
  end

  test 'gesetzter Freitext gewinnt gegen den abgeleiteten Hinweis' do
    game = create(:game, game_day: @game_day, person_level_assignment: true,
                         nominated_referee_string: 'SV Musterstadt')

    assert_equal 'SV Musterstadt', game.public_nominated_referee_string
    assert_equal 'SV Musterstadt', game.schedule_item[:nominated_referee_string]
  end

  # Der Hinweis ist eine Ankündigung. Mit der Voreinstellung „Standardmäßig durch
  # Ansetzer*in" trägt jedes Spiel des Verbands die Markierung – ohne diese
  # Grenze stünde „Ansetzung durch Ansetzer*in" dauerhaft an jedem gespielten
  # Spiel, für das nie ein Gespann eingetragen wurde.
  test 'angepfiffenes Spiel zeigt den Hinweis nicht mehr' do
    game = create(:game, game_day: @game_day, person_level_assignment: true,
                         nominated_referee_string: '', started: true)

    assert_equal '', game.public_nominated_referee_string
    assert_equal '', game.schedule_item[:nominated_referee_string]
  end

  test 'ohne Markierung bleibt die oeffentliche Ausgabe leer' do
    game = create(:game, game_day: @game_day, person_level_assignment: false,
                         nominated_referee_string: '')

    assert_equal '', game.public_nominated_referee_string
    assert_equal '', game.schedule_item[:nominated_referee_string]
  end

  # Der Spiel-Editor der SBK liest den Freitext über meta_hash
  # (GameDay#full_hash(true) → LeaguesController#admin_game_schedule). Bekäme er
  # dort den abgeleiteten Hinweis, lüde er ihn ins Eingabefeld und das nächste
  # Speichern schriebe ihn als echten Freitext in die Datenbank zurück.
  test 'meta_hash liefert den Rohwert und das Flag getrennt' do
    game = create(:game, game_day: @game_day, person_level_assignment: true,
                         nominated_referee_string: '')

    assert_equal '', game.meta_hash[:nominated_referees]
    assert_equal true, game.meta_hash[:person_level_assignment]
  end
end
