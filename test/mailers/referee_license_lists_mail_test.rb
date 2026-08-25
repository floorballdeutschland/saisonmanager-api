require 'test_helper'

# Eine Mail je Empfänger mit allen seinen Spielen des Fensters – wer vier
# Ansetzungen am Wochenende hat, soll nicht vier Mails bekommen.
class RefereeLicenseListsMailTest < ActionMailer::TestCase
  setup do
    travel_to Time.utc(2026, 3, 5, 10, 0)
    create(:setting)
    @league = create(:league, game_operation: create(:game_operation, :national))
    @referee = create(:referee, vorname: 'Ada', email: 'schiri@example.de')
  end

  def entry_for(date, home:, guest:, role: :referee)
    game_day = create(:game_day, league: @league, date: date)
    game = create(:game, game_day: game_day, start_time: '14:00',
                         home_team: create(:team, league: @league, name: home),
                         guest_team: create(:team, league: @league, name: guest))
    link = LicenseListLink.new(game)
    { assignment_id: 0, game: game, date: Date.parse(date), role: role,
      url: link.url, expires_at: link.expires_at }
  end

  test 'ein Spiel: Betreff nennt den Tag, der Rumpf den Link' do
    mail = RefereeMailer.license_lists_notification(
      @referee, [entry_for('2026-03-07', home: 'Heim Team', guest: 'Gast Team')]
    )

    assert_equal ['schiri@example.de'], mail.to
    assert_equal 'Lizenzlisten für deine Ansetzungen (07.03.2026)', mail.subject
    body = mail.html_part ? mail.html_part.body.decoded : mail.body.decoded
    assert_includes body, 'Ada'
    assert_includes body, 'Heim Team'
    assert_includes body, 'Lizenzlisten ansehen'
    assert_includes body, '/lizenzliste?token='
  end

  test 'mehrere Spiele: Betreff nennt den Zeitraum, jedes Spiel einen eigenen Link' do
    entries = [entry_for('2026-03-07', home: 'Heim A', guest: 'Gast A'),
               entry_for('2026-03-09', home: 'Heim B', guest: 'Gast B')]

    mail = RefereeMailer.license_lists_notification(@referee, entries)
    body = mail.body.decoded

    assert_equal 'Lizenzlisten für deine Ansetzungen (07.03.–09.03.2026)', mail.subject
    assert_includes body, 'Heim A'
    assert_includes body, 'Heim B'
    assert_equal 2, body.scan('Lizenzlisten ansehen').size
    assert_not_equal entries.first[:url], entries.last[:url]
  end

  test 'Coach-Ansetzungen sind als solche ausgewiesen' do
    mail = RefereeMailer.license_lists_notification(
      @referee, [entry_for('2026-03-07', home: 'Heim Team', guest: 'Gast Team', role: :coach)]
    )

    assert_includes mail.body.decoded, 'Schiedsrichtercoach'
  end

  # Der Anhang gehört hier nicht hin: Der Termin steckt in der Ansetzungsmail,
  # diese Mail liefert nur die Listen.
  test 'die Lizenzlisten-Mail traegt keinen Kalenderanhang' do
    mail = RefereeMailer.license_lists_notification(
      @referee, [entry_for('2026-03-07', home: 'Heim Team', guest: 'Gast Team')]
    )

    assert_empty mail.attachments
  end

  # Ein in der Admin-UI gepflegter Body ersetzt die Tabelle; über {{game_list}}
  # bleiben die Spiele samt Link wenigstens als Text erreichbar.
  test 'gepflegte Vorlage erreicht die Spiele ueber game_list' do
    EmailTemplate.create!(mailer_class: 'RefereeMailer', action_name: 'license_lists_notification',
                          locale: 'de', body: '<p>Spiele ({{game_count}}): {{game_list}}</p>')

    mail = RefereeMailer.license_lists_notification(
      @referee, [entry_for('2026-03-07', home: 'Heim Team', guest: 'Gast Team')]
    )
    body = mail.body.decoded

    assert_includes body, 'Spiele (1)'
    assert_includes body, '07.03.2026 14:00 Heim Team vs. Gast Team'
  end
end
