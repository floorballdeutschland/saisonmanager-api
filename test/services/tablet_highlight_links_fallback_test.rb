require 'test_helper'

# Ersatzweg für den Highlight-Link (fe#560): Hat am Tablet niemand einen Link
# angefordert, bekommen ihn die Vereinsmanager des Ausrichters, je Übertragung
# höchstens einmal.
class TabletHighlightLinksFallbackTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @now = Time.zone.parse('2026-10-11 23:00:00')
    @start = Time.zone.parse('2026-10-11 17:50:00')
    @ausrichter = create(:club)
    @game_day = create(:game_day, club: @ausrichter)
    @game = create(:game, game_day: @game_day, ended: true, tablet_capture_at: @start,
                          live_stream_link: 'https://www.youtube.com/watch?v=vid-1')
    @broadcast = StreamBroadcast.create!(broadcast_id: 'vid-1', game: @game, actual_start_at: @start,
                                         vod_duration_seconds: 7200)
    GameShot.create!(game: @game, client_uuid: 'm1', kind: 'mark', period: 1, tapped_at: @start + 20.minutes)
    @vm = vm('vm@ausrichter.de')
    ActionMailer::Base.deliveries.clear
  end

  def vm(email, club: @ausrichter)
    create(:user, :vm, club_id: club.id, email: email)
  end

  def lauf(now: @now, dry_run: false)
    TabletHighlightLinks.new(now: now, dry_run: dry_run).run
  end

  def mailtext(mail)
    mail.html_part ? mail.html_part.body.to_s : mail.body.to_s
  end

  test 'ohne Anfrage geht der Link an die Vereinsmanager des Ausrichters' do
    zweiter = vm('zwei@ausrichter.de')
    vm('fremd@anderer.de', club: create(:club))

    ergebnis = lauf

    assert_equal [@game.id, @game.id], ergebnis.sent
    assert_equal %w[vm@ausrichter.de zwei@ausrichter.de], ActionMailer::Base.deliveries.flat_map(&:to).sort
    anfragen = TabletHighlightRequest.where(game: @game)
    assert_equal [@vm.id, zweiter.id].sort, anfragen.pluck(:user_id).sort
    assert(anfragen.all?(&:host_fallback))
    assert(anfragen.all? { |anfrage| anfrage.email.nil? }, 'keine Adresse gespeichert, nur das Konto')
    assert_equal @now.to_i, @broadcast.reload.highlight_fallback_at.to_i
    assert_match(/ausrichtenden Vereins/, mailtext(ActionMailer::Base.deliveries.first))
  end

  test 'von der Vereinspost abgewählte Vereinsmanager und Konten ohne Adresse bekommen nichts' do
    abgewaehlt = vm('ab@ausrichter.de')
    vm(nil)
    @ausrichter.update!(notify_excluded_user_ids: [abgewaehlt.id])

    lauf

    assert_equal ['vm@ausrichter.de'], ActionMailer::Base.deliveries.flat_map(&:to)
  end

  test 'höchstens MAX_PENDING_PER_GAME Empfänger' do
    6.times { |i| vm("vm#{i}@ausrichter.de") }

    lauf

    assert_equal TabletHighlightRequest::MAX_PENDING_PER_GAME, TabletHighlightRequest.where(game: @game).count
    assert_equal TabletHighlightRequest::MAX_PENDING_PER_GAME, ActionMailer::Base.deliveries.size
  end

  test 'kein Ersatz, wenn jemand am Tablet angefordert hat' do
    TabletHighlightRequest.create!(game: @game, email: 'kamera@verein.de')

    lauf

    assert_equal ['kamera@verein.de'], ActionMailer::Base.deliveries.flat_map(&:to)
    assert_nil @broadcast.reload.highlight_fallback_at
  end

  test 'kein Ersatz, wenn der angeforderte Link schon verschickt ist' do
    TabletHighlightRequest.create!(game: @game, email: 'kamera@verein.de').issue_token!(@now - 1.hour)

    lauf

    assert_empty ActionMailer::Base.deliveries
  end

  test 'kein Ersatz für eine schon kalibrierte Aufzeichnung' do
    @broadcast.update!(offset_seconds: 20, calibrated_at: @now - 1.hour, calibrated_via: 'user')

    lauf

    assert_empty ActionMailer::Base.deliveries
    assert_not TabletHighlightRequest.exists?
  end

  test 'kein Ersatz ohne Tabletmodus' do
    @game.update_columns(tablet_capture_at: nil)

    lauf

    assert_empty ActionMailer::Base.deliveries
    assert_not TabletHighlightRequest.exists?
  end

  test 'kein Ersatz, solange die Aufzeichnung nicht fertig ist, danach schon' do
    @broadcast.update!(vod_duration_seconds: nil)
    lauf
    assert_empty ActionMailer::Base.deliveries
    assert_nil @broadcast.reload.highlight_fallback_at

    @broadcast.update!(vod_duration_seconds: 7200)
    lauf(now: @now + 5.minutes)
    assert_equal ['vm@ausrichter.de'], ActionMailer::Base.deliveries.flat_map(&:to)
  end

  test 'kein Ersatz für eine nicht veröffentlichte Aufzeichnung' do
    @game.update_columns(live_stream_link: nil)

    lauf

    assert_empty ActionMailer::Base.deliveries
    assert_nil @broadcast.reload.highlight_fallback_at
  end

  test 'kein Ersatz für alte Spiele' do
    lauf(now: @start + TabletHighlightRequest::PENDING_MAX_AGE + 1.day)

    assert_empty ActionMailer::Base.deliveries
    assert_not TabletHighlightRequest.exists?
  end

  test 'kein Ersatz, wenn er für die Übertragung schon geprüft wurde' do
    @broadcast.update_columns(highlight_fallback_at: @now - 1.day)

    lauf

    assert_empty ActionMailer::Base.deliveries
  end

  test 'kein zweiter Ersatz, nachdem die Anfragen weggeräumt sind' do
    lauf
    assert_equal 1, ActionMailer::Base.deliveries.size

    TabletHighlightRequest.delete_all
    lauf(now: @now + 5.minutes)

    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test 'ohne Vereinsmanager: vermerkt, Hinweis in den Notizen, kein neuer Versuch' do
    @vm.destroy!

    ergebnis = lauf

    assert_empty ActionMailer::Base.deliveries
    assert_not TabletHighlightRequest.exists?
    assert_match(/keinen Vereinsmanager/, ergebnis.notes.join)
    assert_empty ergebnis.probleme
    assert_not_nil @broadcast.reload.highlight_fallback_at

    assert_empty lauf(now: @now + 5.minutes).notes, 'nicht alle fünf Minuten erneut'
  end

  test 'ohne Ausrichter: vermerkt, kein Versand' do
    @game_day.update_columns(club_id: nil)

    ergebnis = lauf

    assert_empty ActionMailer::Base.deliveries
    assert_match(/keinen Vereinsmanager/, ergebnis.notes.join)
    assert_not_nil @broadcast.reload.highlight_fallback_at
  end

  test 'Probelauf legt nichts an und vermerkt nichts' do
    ergebnis = lauf(dry_run: true)

    assert_empty ActionMailer::Base.deliveries
    assert_not TabletHighlightRequest.exists?
    assert_nil @broadcast.reload.highlight_fallback_at
    assert_match(/ginge ersatzweise an 1 Vereinsmanager/, ergebnis.notes.join)
  end

  test 'angeforderter Link behält seinen Text' do
    TabletHighlightRequest.create!(game: @game, email: 'kamera@verein.de')

    lauf

    text = mailtext(ActionMailer::Base.deliveries.last)
    assert_match(/Du hast beim Beenden des Tabletmodus darum gebeten/, text)
    assert_no_match(/ausrichtenden Vereins/, text)
  end
end
