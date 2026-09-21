require 'test_helper'

# Die Mail nannte nur den Portal-Link. Was die beiden Knoepfe dort ausloesen,
# stand nirgends, vor allem nicht, dass „Nicht ordnungsgemaess" noch nichts
# meldet, sondern erst die Checkliste oeffnet. Schiedsrichter*innen haben
# deshalb nachgefragt, was nach dem Klick passiert.
class RefereePortalNoticeTest < ActionMailer::TestCase
  setup do
    create(:setting)
    sa = create(:state_association, sbk_email: 'sbk@example.de')
    go = create(:game_operation, state_association_id: sa.id)
    league = create(:league, game_operation: go)
    club = create(:club, state_association_id: sa.id)
    game_day = GameDay.create!(league: league, arena: create(:arena), club: club, number: 1, date: '2026-01-10')
    @game = Game.create!(
      game_day: game_day,
      home_team: create(:team, league: league, club: club),
      guest_team: create(:team, league: league, club: club),
      game_number: '101',
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )
  end

  # Die Beschriftungen stehen im Frontend (refereeSelf.gameDays.confirmProper /
  # .reportImproper / .submitReport) und muessen hier wortgleich
  # auftauchen: eine Erklaerung zu einem Knopf, den es so nicht gibt, hilft niemandem.
  test 'die Mail erklaert beide Knoepfe des Portals' do
    assert_includes body_of_notice, 'Ordnungsgemäß bestätigen'
    assert_includes body_of_notice, 'Nicht ordnungsgemäß'
    assert_includes body_of_notice, 'Meldung absenden'
  end

  test 'die Mail sagt, dass erst das Absenden die SBK erreicht' do
    assert_match(/Gemeldet wird erst mit .Meldung absenden/, body_of_notice)
    assert_includes body_of_notice, 'SBK'
  end

  private

  # Die Vorlage liefert nur HTML, dann ist html_part nil und der Rumpf haengt
  # direkt an der Mail. decoded statt body.encoded, sonst stehen die Umlaute
  # quoted-printable in der Zeichenkette und keine Zusicherung greift.
  def body_of_notice
    mail = GameMailer.checklist_referee_portal_notice(@game, ['schiri@example.de'])
    (mail.html_part || mail).decoded
  end
end
