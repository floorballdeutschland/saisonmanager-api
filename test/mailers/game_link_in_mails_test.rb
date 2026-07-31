require 'test_helper'

# Die Mails, die auf ein Spiel verlinken, müssen Game#url nutzen. Der frühere
# handgebaute Pfad /spielbericht/:id existiert im Frontend nicht: die zwei
# Segmente treffen die öffentliche Verbandsroute (:association/:leagueId), die
# Seite bleibt leer statt einen Fehler zu zeigen. Diese Tests halten die drei
# Aufrufstellen fest, damit ein Rückfall auffällt.
class GameLinkInMailsTest < ActionMailer::TestCase
  setup do
    create(:setting)
    @sa = create(:state_association, vsk_email: 'vsk@example.de', sbk_email: 'sbk@example.de')
    # Kurzname mit Punkt und Leerzeichen: hier weicht slug von short_name.downcase ab.
    @go = create(:game_operation, short_name: '1. FBL', path: nil, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    @game = Game.create!(
      game_day: @game_day,
      home_team: create(:team, league: @league, club: @club),
      guest_team: create(:team, league: @league, club: @club),
      game_number: '101',
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )
    @expected_url = "#{FrontendUrl.base}/1-fbl/#{@league.id}/spiel/#{@game.id}"
  end

  test 'Erinnerung an das Berichtsformular verlinkt die Spielseite' do
    r1 = create(:referee, email: 'ref1@example.de')
    r2 = create(:referee, email: 'ref2@example.de')

    mail = RefereeMailer.incident_report_reminder(r1, r2, @game, Time.current + 24.hours)

    assert_includes mail.body.encoded, @expected_url
    assert_not_includes mail.body.encoded, '/spielbericht/'
  end

  test 'Scan-Erinnerung an den Ausrichter verlinkt die Spielseite' do
    @club.update!(contact_email: 'ausrichter@example.de')

    mail = ClubMailer.game_day_scan_reminder(@club, @game_day)

    assert_includes mail.body.encoded, @expected_url
  end

  test 'Spielseite im Ticker-Hash nutzt dieselbe Route' do
    assert_equal @expected_url, @game.ticker_hash[:url]
  end
end
