require 'test_helper'

# Ersatzweg für den Highlight-Link (fe#560): Hat am Tablet niemand einen Link
# angefordert, bekommt ihn das Konto, mit dem am Tablet erfasst wurde
# (`game_shots.created_by`), je Übertragung höchstens einmal.
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
    @erfasser = create(:user, email: 'tablet@verein.de')
    szenen(@erfasser)
    # Der Vereinsmanager des Ausrichters bekommt nichts, er hat nicht erfasst.
    create(:user, :vm, club_id: @ausrichter.id, email: 'vm@ausrichter.de')
    ActionMailer::Base.deliveries.clear
  end

  def szenen(user, anzahl = 1, game: @game)
    @szene_nr ||= 0
    anzahl.times do
      @szene_nr += 1
      GameShot.create!(game: game, client_uuid: "m#{@szene_nr}", kind: 'mark', period: 1,
                       tapped_at: @start + @szene_nr.minutes, created_by: user&.id)
    end
  end

  def lauf(now: @now, dry_run: false)
    TabletHighlightLinks.new(now: now, dry_run: dry_run).run
  end

  def empfaenger
    ActionMailer::Base.deliveries.flat_map(&:to)
  end

  def mailtext(mail)
    mail.html_part ? mail.html_part.body.to_s : mail.body.to_s
  end

  test 'ohne Anfrage geht der Link an das Konto, das am Tablet angemeldet erfasst hat' do
    ergebnis = lauf

    assert_equal [@game.id], ergebnis.sent
    assert_equal ['tablet@verein.de'], empfaenger
    anfrage = TabletHighlightRequest.find_by!(game: @game)
    assert_equal @erfasser.id, anfrage.user_id
    assert anfrage.fallback
    assert_nil anfrage.email, 'keine Adresse gespeichert, nur das Konto'
    assert_equal @now.to_i, @broadcast.reload.highlight_fallback_at.to_i

    text = mailtext(ActionMailer::Base.deliveries.first)
    assert_match(/hat niemand den Link zum Bearbeiten der Highlights angefordert/, text)
    assert_match(/mit deinem Konto erfasst/, text)
    assert_match(/außer an die Person, die über deinen Spielsekretariats-Link am Tablet saß/, text)
    assert_no_match(/Du hast beim Beenden des Tabletmodus darum gebeten/, text)
  end

  test 'über den Spielsekretariats-Link erfasst: der Link geht an das Konto, das ihn ausgestellt hat' do
    GameShot.where(game: @game).delete_all
    aussteller = create(:user, :vm, club_id: @ausrichter.id, email: 'aussteller@ausrichter.de')
    link, = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: aussteller)
    # So trägt GameShotsController#secretary_or_current_user_id ohne Sitzung ein.
    szenen(User.find(link.created_by_id), 3)

    lauf

    assert_equal ['aussteller@ausrichter.de'], empfaenger
    assert_equal [aussteller.id], TabletHighlightRequest.where(game: @game).pluck(:user_id)
  end

  test 'mehrere Tablet-Konten: das mit den meisten Einträgen zuerst, bei Gleichstand die kleinere id' do
    viel = create(:user, email: 'viel@verein.de')
    gleich = create(:user, email: 'gleich@verein.de')
    szenen(viel, 3)
    szenen(gleich, 1)
    szenen(nil, 5) # ohne Konto erfasst, zählt für niemanden

    lauf

    anfragen = TabletHighlightRequest.where(game: @game).order(:id)
    assert_equal [viel.id, @erfasser.id, gleich.id], anfragen.pluck(:user_id)
    assert(anfragen.all?(&:fallback))
    assert_equal %w[gleich@verein.de tablet@verein.de viel@verein.de], empfaenger.sort
  end

  test 'Einträge in anderen Spielen zählen nicht' do
    anderes = create(:game, game_day: @game_day)
    szenen(create(:user, email: 'fremd@verein.de'), 4, game: anderes)

    lauf

    assert_equal ['tablet@verein.de'], empfaenger
  end

  test 'höchstens MAX_PENDING_PER_GAME Empfänger, die mit den meisten Einträgen' do
    viele = Array.new(6) { |i| create(:user, email: "konto#{i}@verein.de") }
    viele.each_with_index { |user, i| szenen(user, i + 2) }

    lauf

    max = TabletHighlightRequest::MAX_PENDING_PER_GAME
    assert_equal max, ActionMailer::Base.deliveries.size
    assert_equal viele.last(max).reverse.map(&:id),
                 TabletHighlightRequest.where(game: @game).order(:id).pluck(:user_id)
  end

  test 'archivierte Konten und Konten ohne Adresse bekommen nichts' do
    archiviert = create(:user, email: 'archiv@verein.de')
    szenen(archiviert, 5)
    archiviert.archive!(nil)
    ohne_adresse = create(:user)
    ohne_adresse.update_columns(email: nil)
    szenen(ohne_adresse, 4)
    leer = create(:user)
    leer.update_columns(email: '')
    szenen(leer, 3)

    lauf

    assert_equal ['tablet@verein.de'], empfaenger
    assert_equal [@erfasser.id], TabletHighlightRequest.where(game: @game).pluck(:user_id)
  end

  test 'kein Ersatz, wenn jemand am Tablet angefordert hat' do
    TabletHighlightRequest.create!(game: @game, email: 'kamera@verein.de')

    lauf

    assert_equal ['kamera@verein.de'], empfaenger
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
    assert_equal ['tablet@verein.de'], empfaenger
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

  test 'ohne Tablet-Konto mit Adresse: vermerkt, Hinweis in den Notizen, kein neuer Versuch' do
    @erfasser.update_columns(email: nil)

    ergebnis = lauf

    assert_empty ActionMailer::Base.deliveries
    assert_not TabletHighlightRequest.exists?
    assert_match(/niemand angefordert, und kein Tablet-Konto mit Adresse/, ergebnis.notes.join)
    assert_match(/Kalibrieren nur über Admin oder SBK/, ergebnis.notes.join)
    assert_empty ergebnis.probleme
    assert_not_nil @broadcast.reload.highlight_fallback_at

    assert_empty lauf(now: @now + 5.minutes).notes, 'nicht alle fünf Minuten erneut'
  end

  test 'nur ohne Konto erfasst: vermerkt, kein Versand' do
    GameShot.where(game: @game).update_all(created_by: nil)

    ergebnis = lauf

    assert_empty ActionMailer::Base.deliveries
    assert_match(/kein Tablet-Konto mit Adresse/, ergebnis.notes.join)
    assert_not_nil @broadcast.reload.highlight_fallback_at
  end

  test 'Probelauf legt nichts an und vermerkt nichts' do
    ergebnis = lauf(dry_run: true)

    assert_empty ActionMailer::Base.deliveries
    assert_not TabletHighlightRequest.exists?
    assert_nil @broadcast.reload.highlight_fallback_at
    assert_match(/ginge ersatzweise an die Tablet-Konten \(1\)/, ergebnis.notes.join)
  end

  test 'angeforderter Link behält seinen Text' do
    TabletHighlightRequest.create!(game: @game, email: 'kamera@verein.de')

    lauf

    text = mailtext(ActionMailer::Base.deliveries.last)
    assert_match(/Du hast beim Beenden des Tabletmodus darum gebeten/, text)
    assert_match(/Gib ihn bitte nicht weiter: Wer ihn hat/, text)
    assert_no_match(/mit deinem Konto erfasst/, text)
  end
end
