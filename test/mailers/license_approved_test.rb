require 'test_helper'

# Die Mail über die erteilte Lizenz baute ihren Betreff aus
# `Setting.current_season['name']`. Der seasons-Hash ist aber nicht typsicher, und
# beide Fehlformen scheiterten leise: Unter einem blanken String liefert
# `String#[]('name')` nil (es sucht einen Teilstring), und fehlt der Key ganz, gab
# es einen NoMethodError. Weil die Mail über `deliver_later` läuft, kam sie im
# zweiten Fall einfach nicht an, ohne dass jemand etwas merkte.
#
# Umlaut-Prüfungen über `subject`, nicht über `body.encoded`: Letzteres ist
# quoted-printable.
class LicenseApprovedTest < ActionMailer::TestCase
  setup do
    @club = create(:club)
    @league = create(:league, :current_season, name: 'Regionalliga Bayern')
    @team = create(:team, league: @league, club: @club, name: 'Mittelnkirchen 1')
    @player = create(:player, first_name: 'Leon', last_name: 'Beispiel', email: 'leon@example.de')
  end

  test 'Betreff nennt Mannschaft, Liga und Saison' do
    create(:setting, current_season_id: '18')

    mail = PlayerMailer.license_approved(@player, @team)

    assert_equal ['leon@example.de'], mail.to
    assert_equal 'Lizenz erteilt – Mittelnkirchen 1 (Regionalliga Bayern) - Saison 2025/26', mail.subject
  end

  test 'Saison als blanker String wird gelesen statt stillschweigend verschluckt' do
    create(:setting, current_season_id: '18', seasons: { '18' => 'Saison 2025/26' })

    mail = PlayerMailer.license_approved(@player, @team)

    assert_includes mail.subject, 'Saison 2025/26'
  end

  # Der harte Fall: Ohne Eintrag unter der aktuellen Saison brach die Mail mit
  # NoMethodError ab. Hinter deliver_later heißt das: keine Mail, keine Meldung.
  test 'fehlender Saison-Eintrag bricht die Mail nicht ab' do
    create(:setting, current_season_id: '18', seasons: {})

    mail = nil
    assert_nothing_raised { mail = PlayerMailer.license_approved(@player, @team) }

    assert_equal 'Lizenz erteilt – Mittelnkirchen 1 (Regionalliga Bayern)', mail.subject,
                 'ohne lesbaren Saisonnamen endet der Betreff nicht auf " - "'
  end

  test 'ohne lesbaren Saisonnamen bleibt das Trennzeichen weg' do
    create(:setting, current_season_id: '18', seasons: { '18' => { 'name' => '' } })

    mail = PlayerMailer.license_approved(@player, @team)

    assert_not mail.subject.end_with?(' - ')
  end

  test 'die Mail geht auch ohne Liga an der Mannschaft heraus' do
    create(:setting, current_season_id: '18')
    @team.update_columns(league_id: nil)

    mail = nil
    assert_nothing_raised { mail = PlayerMailer.license_approved(@player, @team.reload) }

    assert_includes mail.subject, 'Mittelnkirchen 1'
  end
end
