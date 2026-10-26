require 'test_helper'

# Der Rohtoken steht nur in dieser Mail. Gerendert wird deshalb wirklich, und
# beide Fassungen (angefordert und Ersatzversand) werden geprüft.
class TabletHighlightMailerTest < ActionMailer::TestCase
  setup do
    create(:setting)
    @league = create(:league)
    @club = create(:club)
    @game_day = create(:game_day, league: @league, club: @club)
    @game = create(:game,
                   game_day: @game_day,
                   game_number: '101',
                   home_team: create(:team, league: @league, club: @club, name: 'Heim'),
                   guest_team: create(:team, league: @league, club: @club, name: 'Gast'),
                   players: { 'home' => [], 'guest' => [] })
    @expires_at = Time.zone.parse('2026-11-07 17:30 UTC')
  end

  def body_of(mail)
    (mail.html_part || mail).decoded
  end

  test 'angefordert: Betreff ohne Gedankenstrich, Link, Spielseite und Abgleich in einem Klick' do
    mail = TabletHighlightMailer.calibration_link(@game, 'tablet@example.com', 'abc/def', @expires_at)
    body = body_of(mail)

    assert_equal ['tablet@example.com'], mail.to
    assert_equal 'Kalibrierung erforderlich: Spiel 101, Heim gegen Gast', mail.subject
    assert_includes body, '/highlights/bearbeiten?token=abc%2Fdef'
    assert_includes body, @game.url
    assert_includes body, 'klick einmal in dem Moment, in dem das Tor fällt'
    assert_includes body, 'eine einzelne Szene kalibrieren'
    assert_includes body, 'nur an die Adresse, für die der Link angefordert wurde'
    assert_includes body, '07.11.2026 18:30 Uhr'
    assert_not_includes body, 'Spielsekretariats-Link'
  end

  test 'Ersatzversand nennt den Grund und den Empfängerkreis' do
    mail = TabletHighlightMailer.calibration_link(@game, 'tablet@example.com', 'abc', @expires_at, fallback: true)
    body = body_of(mail)

    assert_includes body, 'hat niemand den Link zum Bearbeiten angefordert'
    assert_includes body, 'nur an die Konten, mit denen am Tablet erfasst wurde'
    assert_not_includes body, 'nur an die Adresse, für die der Link angefordert wurde'
  end
end
