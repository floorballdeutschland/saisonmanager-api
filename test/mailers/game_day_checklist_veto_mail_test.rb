require 'test_helper'

# Die SBK muss eine Spieltagsmeldung einem Spiel zuordnen koennen: Spielnummer,
# Anwurf und beide Mannschaften gehoeren in die Mail, nicht nur Liga und Datum.
# Testtexte bewusst ohne Umlaute, damit die quoted-printable-Kodierung des
# Bodys die Suche nicht zerlegt.
class GameDayChecklistVetoMailTest < ActionMailer::TestCase
  setup do
    create(:setting)
    @sa = create(:state_association, sbk_email: 'sbk@example.de')
    @league = create(:league, game_operation: create(:game_operation, state_association: @sa))
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: create(:club),
                                number: 1, date: '2026-09-20')
    @referee = create(:referee)
    @own = build_game('12', '14:30', 'Adler Nord', 'Falken Sued')
    @other = build_game('13', '16:30', 'Baeren West', 'Woelfe Ost')
    publish(@own, @referee)
    publish(@other, create(:referee))
  end

  test 'Schiri-Meldung nennt Spielnummer und Mannschaften der eigenen Spiele' do
    body = GameDayMailer.referee_checklist_veto(@game_day, @referee, [], @sa).body.encoded

    assert_includes body, 'Nr. 12, 14:30 Uhr: Adler Nord vs. Falken Sued'
    assert_not_includes body, 'Baeren West', 'fremdes Spiel des Spieltags gehoert nicht dazu'
  end

  test 'ohne passende Ansetzung stehen alle Spiele des Spieltags drin' do
    body = GameDayMailer.referee_checklist_veto(@game_day, create(:referee), [], @sa).body.encoded

    assert_includes body, 'Adler Nord vs. Falken Sued'
    assert_includes body, 'Baeren West vs. Woelfe Ost'
  end

  test 'Mannschafts-Meldung nennt die Spiele der meldenden Mannschaft' do
    body = GameDayMailer.team_checklist_veto(@game_day, @other.guest_team, [], @sa).body.encoded

    assert_includes body, 'Nr. 13, 16:30 Uhr: Baeren West vs. Woelfe Ost'
    assert_not_includes body, 'Adler Nord'
  end

  test 'gespeicherte Vorlage kann die Spiele ueber {{games}} einsetzen' do
    EmailTemplate.create!(mailer_class: 'GameDayMailer', action_name: 'referee_checklist_veto',
                          body: 'Betroffen: {{games}}')

    body = GameDayMailer.referee_checklist_veto(@game_day, @referee, [], @sa).body.encoded

    assert_includes body, 'Betroffen: Nr. 12, 14:30 Uhr: Adler Nord vs. Falken Sued'
  end

  private

  def build_game(number, time, home, guest)
    Game.create!(game_day: @game_day, game_number: number, start_time: time,
                 home_team: create(:team, league: @league, name: home),
                 guest_team: create(:team, league: @league, name: guest),
                 forfait: 0, overtime: false, legacy: false,
                 events: [], players: { 'home' => [], 'guest' => [] })
  end

  def publish(game, referee)
    RefereeAssignment.create!(game: game, referee1: referee, status: 'published', published_at: Time.current)
  end
end
