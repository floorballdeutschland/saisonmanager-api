require 'test_helper'

# Der Watchdog beendet Übertragungen unwiderruflich -- zurückholen lässt sich
# eine beendete Sendung nicht. Deshalb steht zu jeder Abschaltregel hier auch
# die Gegenprobe, dass sie in der Nachbarlage NICHT greift.
class StreamWatchdogTest < ActiveSupport::TestCase
  # Ersetzt YoutubeLiveApi. Hält fest, was beendet wurde, statt es zu tun.
  class FakeApi
    attr_reader :completed

    def initialize(broadcasts: [], streams: {})
      @broadcasts = broadcasts
      @streams = streams
      @completed = []
    end

    def active_broadcasts
      @broadcasts
    end

    def streams(ids)
      @streams.slice(*Array(ids))
    end

    def complete!(broadcast_id)
      @completed << broadcast_id
      {}
    end
  end

  STREAM_ID = 'stream-1'.freeze
  STREAM_KEY = 'abcd-efgh-ijkl-mnop-qrst'.freeze
  BROADCAST_ID = 'bc-1'.freeze

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club,
                                number: 1, date: '2026-03-07')
    @home = create(:team, league: @league, club: @club, stream_key: STREAM_KEY)
    @guest = create(:team, league: @league, club: @club)
    @game = spiel_anlegen('18:00')

    # Anwurf 18:00 Berlin, "jetzt" zwei Stunden später -- das Spiel läuft oder
    # ist eben zu Ende.
    @now = Time.zone.parse('2026-03-07 20:00:00 +01:00')
  end

  # --- Regel: 15 Minuten ohne Signal UND Spielbericht geschlossen ------------

  test 'beendet, wenn seit 15 Minuten kein Signal anliegt und der Spielbericht geschlossen ist' do
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 20.minutes)
    api = api_mit(status: 'inactive')

    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.completed
    assert_equal 1, ergebnis[:ended].size
    satz = StreamBroadcast.find_by(broadcast_id: BROADCAST_ID)
    assert satz.ended?
    assert_match(/Spielbericht geschlossen/, satz.ended_reason)
    assert_equal @game.id, satz.game_id
  end

  test 'GEGENPROBE: geschlossener Spielbericht, aber erst 5 Minuten ohne Signal -- nichts wird beendet' do
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 5.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert_not StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).ended?
  end

  test 'GEGENPROBE: 20 Minuten ohne Signal, aber der Spielbericht ist offen -- nichts wird beendet' do
    # Der eigentliche Zweck der zweiten Bedingung: Drittelpause, Netzausfall in
    # der Halle, Kamerawechsel. Nach der alten Regel (nur Zeit) wäre die
    # Übertragung hier mitten im Spiel abgeschaltet worden.
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert_not StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).ended?
  end

  test 'GEGENPROBE: Signal liegt an, Spielbericht geschlossen -- nichts wird beendet' do
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 60.minutes)

    api = api_mit(status: 'active')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    satz = StreamBroadcast.find_by(broadcast_id: BROADCAST_ID)
    assert_nil satz.signal_lost_at, 'Signal wieder da: der Timer muss zurückgesetzt sein'
    assert_equal @now.to_i, satz.last_active_at.to_i
  end

  test 'finalized zählt wie match_record_closed' do
    @game.update!(game_status: 'finalized')
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.completed
  end

  # --- Ausnahme 1: Übergabe an das nächste Spiel ----------------------------

  test 'beendet bei offenem Spielbericht, wenn gleich das nächste Heimspiel auf demselben Schlüssel startet' do
    spiel_anlegen('20:10')
    satz_anlegen(signal_lost_at: nil)

    api = api_mit(status: 'active')
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.completed
    assert_match(/nächste Spiel/, StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).ended_reason)
  end

  test 'GEGENPROBE: nächstes Heimspiel erst in zwei Stunden -- keine Übergabe' do
    spiel_anlegen('22:00')
    satz_anlegen(signal_lost_at: nil)

    api = api_mit(status: 'active')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
  end

  # --- Ausnahme 2: Notabschaltung -------------------------------------------

  test 'Notabschaltung nach drei Stunden ohne Signal, auch wenn der Spielbericht offen bleibt' do
    satz_anlegen(signal_lost_at: @now - 200.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.completed
    assert_match(/Notabschaltung/, StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).ended_reason)
  end

  test 'Übertragung ohne zugeordnetes Spiel wird nur von der Notabschaltung erfasst' do
    # Tagesstream einer Deutschen Meisterschaft: Der Schlüssel gehört keiner
    # Mannschaft, ein Spielbericht kann die Lage also nie klären.
    @home.update!(stream_key: nil)
    satz_anlegen(signal_lost_at: @now - 30.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run
    assert_empty api.completed, 'ohne Spiel darf die 15-Minuten-Regel nicht greifen'

    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).update!(signal_lost_at: @now - 200.minutes)
    StreamWatchdog.new(api: api, now: @now).run
    assert_equal [BROADCAST_ID], api.completed
    assert_match(/kein Spiel zugeordnet/, StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).ended_reason)
  end

  # --- Zuordnung Schlüssel -> Spiel -----------------------------------------

  test 'mehrdeutiger Schlüssel ordnet kein Spiel zu und beendet nichts' do
    # Derselbe Schlüssel an zwei Mannschaften, beide heute mit Heimspiel: Der
    # Watchdog darf nicht raten, welche gerade sendet.
    zweite_liga = create(:league, game_operation: @go)
    zweiter_spieltag = GameDay.create!(league: zweite_liga, arena: @arena, club: @club,
                                       number: 1, date: '2026-03-07')
    zweites_heim = create(:team, league: zweite_liga, club: @club, stream_key: STREAM_KEY)
    Game.create!(game_day: zweiter_spieltag, home_team: zweites_heim,
                 guest_team: create(:team, league: zweite_liga, club: @club),
                 start_time: '18:00', forfait: 0, overtime: false, legacy: false,
                 game_status: 'match_record_closed',
                 events: [], players: { 'home' => [], 'guest' => [] })
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    api = api_mit(status: 'inactive')
    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert_nil StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).game_id
    assert(ergebnis[:notes].any? { |n| n.include?('mehrere Mannschaften') })
  end

  test 'ein Spiel von gestern gilt nicht mehr als das laufende' do
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    # 20 Stunden nach Anwurf: außerhalb des Rückblicks von zwölf Stunden.
    spaeter = @now + 18.hours
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).update!(signal_lost_at: spaeter - 20.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: spaeter).run

    assert_empty api.completed, 'ohne Zuordnung greift nur die Notabschaltung, und die ist noch nicht fällig'
  end

  # --- Betrieb ---------------------------------------------------------------

  test 'Probelauf beendet nichts, meldet es aber' do
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    api = api_mit(status: 'inactive')
    ergebnis = StreamWatchdog.new(api: api, dry_run: true, now: @now).run

    assert_empty api.completed
    assert_not StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).ended?
    assert(ergebnis[:notes].any? { |n| n.include?('[Probelauf] würde beenden') })
  end

  test 'ein Satz zu einer nicht mehr laufenden Übertragung wird geschlossen' do
    satz_anlegen(signal_lost_at: @now - 5.minutes)

    ergebnis = StreamWatchdog.new(api: FakeApi.new, now: @now).run

    satz = StreamBroadcast.find_by(broadcast_id: BROADCAST_ID)
    assert satz.ended?
    assert_equal 'auf YouTube nicht mehr aktiv', satz.ended_reason
    assert_equal 1, ergebnis[:closed_stale].size
  end

  test 'Übertragung ohne gebundenen Stream wird übersprungen, nicht beendet' do
    api = FakeApi.new(broadcasts: [{ id: BROADCAST_ID, title: 'Ohne Stream', stream_id: nil }])

    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert(ergebnis[:notes].any? { |n| n.include?('kein gebundener Stream') })
  end

  test 'ein Fehlschlag beim Beenden bricht den Lauf nicht ab und lässt den Satz offen' do
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    api = api_mit(status: 'inactive')
    api.define_singleton_method(:complete!) { |_id| raise YoutubeLiveApi::Error, 'quotaExceeded' }

    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_empty ergebnis[:ended]
    assert_not StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).ended?,
               'der Satz muss offen bleiben, damit der nächste Lauf es erneut versucht'
    assert(ergebnis[:notes].any? { |n| n.include?('FEHLER beim Beenden') })
  end

  private

  def spiel_anlegen(start_time)
    Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest,
                 start_time: start_time, forfait: 0, overtime: false, legacy: false,
                 events: [], players: { 'home' => [], 'guest' => [] })
  end

  def satz_anlegen(signal_lost_at:)
    StreamBroadcast.create!(broadcast_id: BROADCAST_ID, stream_id: STREAM_ID,
                            title: 'Heim vs Gast', signal_lost_at: signal_lost_at)
  end

  def api_mit(status:)
    FakeApi.new(
      broadcasts: [{ id: BROADCAST_ID, title: 'Heim vs Gast', stream_id: STREAM_ID }],
      streams: { STREAM_ID => { status: status, key: STREAM_KEY } }
    )
  end
end
