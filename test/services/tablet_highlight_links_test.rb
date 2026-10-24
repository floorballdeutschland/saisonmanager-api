require 'test_helper'

# Versand der Links zum Kalibrieren und Auswählen der Highlights (fe#560).
class TabletHighlightLinksTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @now = Time.zone.parse('2026-10-11 23:00:00')
    @start = Time.zone.parse('2026-10-11 17:50:00')
    @game = create(:game, ended: true, tablet_capture_at: @start, players: { 'home' => [], 'guest' => [] },
                          live_stream_link: 'https://www.youtube.com/watch?v=vid-1')
    @broadcast = StreamBroadcast.create!(broadcast_id: 'vid-1', game: @game, actual_start_at: @start)
    GameShot.create!(game: @game, client_uuid: 'm1', kind: 'mark', period: 1, tapped_at: @start + 20.minutes)
    @anfrage = TabletHighlightRequest.create!(game: @game, email: 'kamera@verein.de', created_at: @now - 3.hours)
    ActionMailer::Base.deliveries.clear
  end

  test 'wartet, solange die Länge der Aufzeichnung fehlt' do
    TabletHighlightLinks.new(now: @now).run

    assert_empty ActionMailer::Base.deliveries
    assert_nil @anfrage.reload.sent_at
  end

  test 'verschickt, sobald die Aufzeichnung fertig ist, und löscht die eingegebene Adresse' do
    @broadcast.update!(vod_duration_seconds: 7200)

    lauf = TabletHighlightLinks.new(now: @now).run

    assert_equal [@game.id], lauf.sent
    mail = ActionMailer::Base.deliveries.last
    assert_equal ['kamera@verein.de'], mail.to
    token = mail.html_part ? mail.html_part.body.to_s[/token=([\w-]+)/, 1] : mail.body.to_s[/token=([\w-]+)/, 1]
    assert token.present?
    @anfrage.reload
    assert_nil @anfrage.email, 'Adresse nach dem Versand weg'
    assert_equal @anfrage, TabletHighlightRequest.find_by_token(token)
    assert_equal (@now + 14.days).to_i, @anfrage.expires_at.to_i

    TabletHighlightLinks.new(now: @now + 5.minutes).run
    assert_equal 1, ActionMailer::Base.deliveries.size, 'kein zweiter Versand'
  end

  test 'nicht veröffentlichte Aufzeichnung: kein Versand' do
    @broadcast.update!(vod_duration_seconds: 7200)
    @game.update_columns(live_stream_link: nil)

    TabletHighlightLinks.new(now: @now).run

    assert_empty ActionMailer::Base.deliveries
  end

  test 'Probelauf verschickt nichts und ändert nichts' do
    @broadcast.update!(vod_duration_seconds: 7200)

    lauf = TabletHighlightLinks.new(now: @now, dry_run: true).run

    assert_empty ActionMailer::Base.deliveries
    assert_equal 'kamera@verein.de', @anfrage.reload.email
    assert_equal 1, lauf.notes.size
  end

  test 'räumt verfallene Anfragen weg, abgelaufene Links erst nach 30 Tagen' do
    @anfrage.update_columns(created_at: @now - 15.days)
    kuerzlich = TabletHighlightRequest.create!(game: @game, email: 'x@y.de')
    kuerzlich.issue_token!(@now - 15.days)
    alt = TabletHighlightRequest.create!(game: @game, email: 'z@y.de')
    alt.issue_token!(@now - 45.days)

    TabletHighlightLinks.new(now: @now).run

    assert_equal [kuerzlich.id], TabletHighlightRequest.pluck(:id),
                 'seit einem Tag abgelaufen: bleibt für die Antwort "abgelaufen" stehen'
  end

  test 'ein Fehler beim Versand bleibt offen und wird gemeldet' do
    @broadcast.update!(vod_duration_seconds: 7200)
    TabletHighlightMailer.stub(:calibration_link, ->(*) { raise 'SMTP weg' }) do
      lauf = TabletHighlightLinks.new(now: @now).run
      assert_match(/SMTP weg/, lauf.probleme.first)
    end

    @anfrage.reload
    assert_nil @anfrage.sent_at
    assert_equal 'kamera@verein.de', @anfrage.email, 'Transaktion zurückgerollt, nächster Lauf versucht es erneut'
    assert_equal 1, @anfrage.send_attempts
  end

  test 'Fehler nach der Annahme: der nächste Lauf schickt DENSELBEN Link' do
    @broadcast.update!(vod_duration_seconds: 7200)
    erster_token = nil
    TabletHighlightMailer.stub(:calibration_link, lambda { |_game, _to, token, _expires, **|
      erster_token = token
      raise Net::ReadTimeout
    }) do
      TabletHighlightLinks.new(now: @now).run
    end

    TabletHighlightLinks.new(now: @now + 5.minutes).run

    mail = ActionMailer::Base.deliveries.last
    body = mail.html_part ? mail.html_part.body.to_s : mail.body.to_s
    assert_equal erster_token, body[/token=([\w-]+)/, 1], 'eine schon zugestellte erste Mail bleibt gültig'
    assert_equal @anfrage, TabletHighlightRequest.find_by_token(erster_token)
  end

  test 'Fehler stehen als PROBLEM in den Notizen, nach fünf Versuchen wird verworfen' do
    @broadcast.update!(vod_duration_seconds: 7200)
    laeufe = []
    TabletHighlightMailer.stub(:calibration_link, ->(*) { raise 'SendAsDenied' }) do
      5.times { |i| laeufe << TabletHighlightLinks.new(now: @now + (i * 5).minutes).run }
    end

    assert_match(/\APROBLEM: .*Versuch 1: .*SendAsDenied/, laeufe.first.notes.first)
    assert_match(/verworfen/, laeufe.last.probleme.first)
    assert_not TabletHighlightRequest.exists?(@anfrage.id), 'Anfrage samt Adresse weg'

    sechster = TabletHighlightLinks.new(now: @now + 30.minutes).run
    assert_empty sechster.probleme, 'danach Ruhe'
  end
end
