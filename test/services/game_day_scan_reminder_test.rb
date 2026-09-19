require 'test_helper'

# Die Erinnerung an fehlende Spielberichtsbogen kommt eine Stunde nach dem
# Abschluss und nur, wenn bis dahin nichts hochgeladen wurde. Vorher ging sie im
# selben Augenblick raus, in dem der letzte Bericht geschlossen wurde -- also
# während der Ausrichter den Bogen noch am Tisch einscannte.
class GameDayScanReminderTest < ActiveSupport::TestCase
  setup do
    # ActiveSupport::TestCase leert den Postausgang nicht selbst, anders als die
    # Integrationstests -- ohne das zaehlen hier die Mails der Vorgaenger mit.
    ActionMailer::Base.deliveries.clear
    create(:setting)
    @sa = create(:state_association, scan_required: true)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id, contact_email: 'verein@example.de')
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club,
                                number: 1, date: 1.day.ago.to_date.to_s)
    @game = closed_game(2.hours.ago)
  end

  test 'eine Stunde nach dem Abschluss ohne Scan wird erinnert' do
    assert_equal 1, GameDayScanReminder.notify_due

    mail = ActionMailer::Base.deliveries.last
    assert_equal ['verein@example.de'], mail.to
    assert_includes mail.subject, 'Spielbericht-Scans einreichen'
    assert_not_nil @game_day.reload.scan_reminder_sent_at
  end

  test 'innerhalb der ersten Stunde wird nicht erinnert' do
    @game.update_columns(match_record_closed_at: 30.minutes.ago)

    assert_equal 0, GameDayScanReminder.notify_due
    assert_nil @game_day.reload.scan_reminder_sent_at
    assert_empty ActionMailer::Base.deliveries
  end

  test 'wer den Bogen hochgeladen hat, bekommt keine Erinnerung' do
    attach_scan(@game)

    assert_equal 0, GameDayScanReminder.notify_due
    assert_empty ActionMailer::Base.deliveries
  end

  test 'fehlt der Scan an einem von zwei Spielen, wird erinnert' do
    zweites = closed_game(2.hours.ago)
    attach_scan(@game)

    assert_equal 1, GameDayScanReminder.notify_due
    assert_not_nil zweites.game_day.reload.scan_reminder_sent_at
  end

  test 'ein noch offener Bericht haelt den Spieltag zurueck' do
    Game.create!(game_day: @game_day, home_team: create(:team, league: @league),
                 guest_team: create(:team, league: @league), game_status: 'open',
                 forfait: 0, overtime: false, legacy: false,
                 events: [], players: { 'home' => [], 'guest' => [] })

    assert_equal 0, GameDayScanReminder.notify_due
  end

  test 'ohne Scan-Pflicht des Verbandes geht keine Erinnerung raus' do
    @sa.update!(scan_required: false)

    assert_equal 0, GameDayScanReminder.notify_due
  end

  test 'ohne Adresse des Ausrichters geht keine Erinnerung raus' do
    @club.update!(contact_email: nil)

    assert_equal 0, GameDayScanReminder.notify_due
    assert_nil @game_day.reload.scan_reminder_sent_at
  end

  test 'erinnert wird nur einmal' do
    assert_equal 1, GameDayScanReminder.notify_due
    assert_equal 0, GameDayScanReminder.notify_due
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  # Ohne Rückschau schriebe der erste Lauf jeden Verein zu jedem je gespielten
  # Spieltag an: `scan_reminder_sent_at` ist im Bestand ueberall leer.
  test 'alte Spieltage bleiben ausserhalb des Rueckschaufensters' do
    @game.update_columns(match_record_closed_at: (GameDayScanReminder::LOOKBACK + 1.day).ago)

    assert_equal 0, GameDayScanReminder.notify_due
  end

  test 'DRY_RUN zaehlt, verschickt aber nichts und markiert nichts' do
    assert_equal 1, GameDayScanReminder.notify_due(dry_run: true)
    assert_empty ActionMailer::Base.deliveries
    assert_nil @game_day.reload.scan_reminder_sent_at
  end

  private

  def closed_game(closed_at)
    Game.create!(
      game_day: @game_day,
      home_team: create(:team, league: @league),
      guest_team: create(:team, league: @league),
      game_status: 'match_record_closed',
      match_record_closed_at: closed_at,
      forfait: 0, overtime: false, legacy: false,
      events: [], players: { 'home' => [], 'guest' => [] }
    )
  end

  def attach_scan(game)
    scan = game.build_game_scan(expires_at: 30.days.from_now)
    scan.scan_file.attach(io: StringIO.new('PDF'), filename: 'bogen.pdf', content_type: 'application/pdf')
    scan.save!
  end
end
