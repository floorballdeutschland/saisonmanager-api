require 'test_helper'

# Die Adresse der gesetzlichen Vertretung wurde bis 1.81.0 nur an der Lizenz
# vermerkt; verschickt wurde nie etwas. Wer sie eintrug, wartete auf eine Mail,
# die es nicht gab.
#
# Umlaut-Prüfungen laufen über body.decoded: body.encoded liefert den
# quoted-printable-Text, in dem „über" nicht mehr als solches vorkommt.
class GuardianPrivacyInfoTest < ActionMailer::TestCase
  setup do
    @setting = create(:setting)
    @sa = create(:state_association, sbk_email: 'sbk@example.de')
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, :current_season, game_operation: @go, name: 'U15 Juniorinnen')
    @club = create(:club)
    @team = create(:team, league: @league, club: @club, name: 'Mittelnkirchen U15')
    @player = create(:player, first_name: 'Leon', last_name: 'Beispiel', birthdate: 15.years.ago.to_date.to_s)
  end

  test 'Mail geht an die angegebene Adresse und nennt Spieler, Verein und Mannschaft' do
    mail = PlayerMailer.guardian_privacy_info(@player, @team, @league, 'eltern@example.de')

    assert_equal ['eltern@example.de'], mail.to
    assert_equal 'Datenschutzinformation zur Lizenzbeantragung – Leon Beispiel', mail.subject
    body = mail.body.decoded
    assert_includes body, 'Leon Beispiel'
    assert_includes body, @club.name
    assert_includes body, 'Mittelnkirchen U15'
    assert_includes body, 'U15 Juniorinnen'
  end

  test 'Antworten gehen an die SBK des Spielbetriebs der Liga' do
    mail = PlayerMailer.guardian_privacy_info(@player, @team, @league, 'eltern@example.de')

    assert_equal ['sbk@example.de'], mail.reply_to
  end

  test 'gepflegtes Informationsblatt wird verlinkt' do
    @setting.update!(info_links: { 'minor_privacy_bundesliga' => { 'url' => 'https://floorball.de/info.pdf' } })

    mail = PlayerMailer.guardian_privacy_info(@player, @team, @league, 'eltern@example.de')

    assert_includes mail.body.decoded, 'https://floorball.de/info.pdf'
  end

  # Ohne gepflegte Adresse lieber auf den Verein verweisen als einen toten Link
  # anbieten.
  test 'ohne gepflegtes Informationsblatt verweist die Mail auf den Verein' do
    mail = PlayerMailer.guardian_privacy_info(@player, @team, @league, 'eltern@example.de')

    assert_includes mail.body.decoded, 'erhalten Sie über den Verein'
    assert_not_includes mail.body.decoded, 'Informationsblatt öffnen'
  end

  # Je nach Altbestand steht unter einer Saison ein Hash oder ein blanker
  # String. Ein `dig` darauf bräche mit TypeError ab, und hinter deliver_later
  # käme die Mail einfach nicht an, ohne dass jemand etwas merkt.
  test 'Saison als blanker String bricht die Mail nicht ab' do
    @setting.update!(seasons: { @league.season_id.to_s => 'Saison 2026/27' })

    mail = PlayerMailer.guardian_privacy_info(@player, @team, @league, 'eltern@example.de')

    assert_includes mail.body.decoded, 'Saison 2026/27'
  end

  test 'ohne lesbaren Saisonnamen bleibt die Zeile weg' do
    @setting.update!(seasons: {})

    mail = PlayerMailer.guardian_privacy_info(@player, @team, @league, 'eltern@example.de')

    assert_not_includes mail.body.decoded, 'Saison:'
    assert_includes mail.body.decoded, 'Leon Beispiel'
  end

  test 'ohne Adresse wird nichts verschickt' do
    assert_emails 0 do
      PlayerMailer.guardian_privacy_info(@player, @team, @league, nil).deliver_now
    end
  end
end
