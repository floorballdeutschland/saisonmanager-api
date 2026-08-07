require 'test_helper'

# Karriere-Ende nach vier Lizenzjahren ohne Lizenz. Die Grenze hängt an der
# aktiven Saison, nicht am Kalender, damit ein vorgezogener Saisonwechsel sofort
# wirkt.
class RefereeCareerStatusTest < ActiveSupport::TestCase
  def setup
    Rails.cache.clear
    create(:setting, current_season_id: '19')
    Setting.current.update!(seasons: { '19' => { 'name' => '2026/2027' } })
    Rails.cache.clear
  end

  def referee_with(gueltigkeit)
    create(:referee, gueltigkeit: gueltigkeit)
  end

  test 'Stichtag ist der Saisonstart vor vier Jahren' do
    assert_equal Date.new(2022, 8, 1), Referee.career_end_cutoff
  end

  test 'Stichtag folgt einem vorgezogenen Saisonwechsel' do
    assert_equal Date.new(2023, 8, 1), Referee.career_end_cutoff(2027)
  end

  test 'Saisonname in der Schreibweise „Saison 2025/26" wird ebenfalls gelesen' do
    Setting.current.update!(seasons: { '19' => { 'name' => 'Saison 2025/26' } })
    Rails.cache.clear

    assert_equal 2025, Setting.current_season_start_year
    assert_equal Date.new(2021, 8, 1), Referee.career_end_cutoff
  end

  test 'Kohorte mit Ablauf 31.07.2022 gilt in der Saison 2026/2027 als beendet' do
    referee = referee_with(Date.new(2022, 7, 31))

    assert_equal :career_ended, referee.license_status
    assert_includes Referee.career_ended, referee
    assert_not_includes Referee.in_career_window, referee
  end

  test 'Kohorte mit Ablauf 30.09.2023 ist abgelaufen, aber nicht beendet' do
    referee = referee_with(Date.new(2023, 9, 30))

    assert_equal :lapsed, referee.license_status
    assert_includes Referee.lapsed, referee
    assert_includes Referee.in_career_window, referee
    assert_not_includes Referee.career_ended, referee
  end

  test 'gültige Lizenz ist aktiv und liegt im Fenster' do
    referee = referee_with(Date.current + 30)

    assert_equal :active, referee.license_status
    assert_includes Referee.in_career_window, referee
    assert_not_includes Referee.lapsed, referee
  end

  test 'ohne Ablaufdatum ist ein eigener Zustand, nicht „beendet"' do
    referee = referee_with(nil)

    assert_equal :unknown, referee.license_status
    assert_not referee.career_ended?
    assert_includes Referee.without_license_proof, referee
    # Für die Sichtbarkeit zählt allein das Fenster, und dort fällt NULL heraus.
    assert_not_includes Referee.in_career_window, referee
    assert_not_includes Referee.career_ended, referee
  end

  test 'career_ended und in_career_window sind überschneidungsfrei' do
    [Date.new(2020, 9, 30), Date.new(2022, 7, 31), Date.new(2023, 9, 30), Date.current + 1].each do |datum|
      referee_with(datum)
    end

    beendet = Referee.career_ended.pluck(:id)
    fenster = Referee.in_career_window.pluck(:id)

    assert_empty beendet & fenster
    assert_equal Referee.where.not(gueltigkeit: nil).count, (beendet | fenster).size
  end
end
