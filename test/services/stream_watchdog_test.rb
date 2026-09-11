require 'test_helper'

# Der Watchdog beendet Übertragungen unwiderruflich -- zurückholen lässt sich
# eine beendete Sendung nicht. Deshalb steht zu jeder Abschaltregel hier auch
# die Gegenprobe, dass sie in der Nachbarlage NICHT greift.
class StreamWatchdogTest < ActiveSupport::TestCase
  # Ersetzt YoutubeLiveApi. Hält fest, was beendet wurde, statt es zu tun.
  class FakeApi
    attr_reader :completed, :published

    def initialize(broadcasts: [], streams: {}, publish_result: :veroeffentlicht, publish_error: nil)
      @broadcasts = broadcasts
      @streams = streams
      @completed = []
      @published = []
      @publish_result = publish_result
      @publish_error = publish_error
    end

    def active_broadcasts
      @broadcasts
    end

    def streams(ids)
      @streams.slice(*Array(ids))
    end

    # Wie der echte Client: was gefunden wurde, und wozu nichts zurückkam.
    def streams_mit_luecken(ids)
      angefragt = Array(ids).compact.uniq
      gefunden = streams(angefragt)
      [gefunden, angefragt - gefunden.keys]
    end

    def complete!(broadcast_id)
      @completed << broadcast_id
      {}
    end

    # Wie der echte Client: :veroeffentlicht, :schon_oeffentlich oder
    # :verschwunden -- oder ein hinterlegter Fehler.
    def publish!(broadcast_id)
      @published << broadcast_id
      raise @publish_error if @publish_error

      @publish_result
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
    # @club richtet aus UND stellt die Heimmannschaft -- der Regelfall. Dass der
    # Schlüssel am Ausrichter hängt und nicht am Heimteam, prüfen die Tests
    # weiter unten, in denen die beiden auseinanderfallen.
    @home = create(:team, league: @league, club: @club, stream_key: STREAM_KEY)
    # Eigener Verein: Zwei Mannschaften desselben Vereins in EINER Liga machen
    # den Ausrichter mehrdeutig, und GameDay#hosting_team antwortet dann bewusst
    # mit nil. Das ist richtig so -- hier soll aber der Normalfall stehen.
    @guest = create(:team, league: @league, club: create(:club))
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

  test 'übergibt an die nächste Partie, wenn die laufende abgeschlossen ist' do
    @game.update!(game_status: 'match_record_closed')
    spiel_anlegen('20:10')
    satz_anlegen(signal_lost_at: nil)

    api = api_mit(status: 'active')
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.completed
    assert_match(/nächste Partie/, StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).ended_reason)
  end

  # Verglichen wird der PAPIERANWURF der nächsten Partie. Zieht sich die laufende
  # (Verlängerung, Penaltyschießen, verspäteter Anwurf), darf der Plan keine
  # sendende Übertragung kappen -- unwiderruflich, mitten im Spiel.
  test 'GEGENPROBE: übergibt nicht, solange gesendet wird und der Bericht offen ist' do
    spiel_anlegen('20:10')
    satz_anlegen(signal_lost_at: nil)

    api = api_mit(status: 'active')
    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert(ergebnis[:problems].any? { |p| p.include?('nicht übergeben') })
  end

  # Wer den Stream eine Viertelstunde vor Anwurf startet (Kameracheck,
  # Einlaufmusik), verlor ihn sonst fünf Minuten vor dem Anpfiff: Die Übergabe
  # sah ein Spiel beginnen und schaltete die Übertragung ab, die genau dazu
  # gehört.
  test 'GEGENPROBE: der Vorlauf zur eigenen Partie ist keine Übergabe' do
    kommendes = spiel_anlegen('20:10')
    satz_anlegen(signal_lost_at: nil)
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).update!(game_id: kommendes.id)

    api = api_mit(status: 'active')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
  end

  # Ein verspäteter Anwurf darf die Übergabe nicht dauerhaft verhindern -- sonst
  # bliebe der Schlüssel bis zur Notabschaltung nach drei Stunden belegt.
  test 'übergibt auch an eine Partie, deren Anwurf schon zurückliegt' do
    @game.update!(game_status: 'match_record_closed')
    verspaetet = spiel_anlegen('19:55')
    satz_anlegen(signal_lost_at: nil)
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).update!(game_id: @game.id)

    api = api_mit(status: 'active')
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.completed
    assert_not_nil verspaetet
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
    # Derselbe Schlüssel an zwei Mannschaften, die heute beide einen Spieltag
    # ausrichten: Der Watchdog darf nicht raten, welcher gerade sendet.
    zweite_liga = create(:league, game_operation: @go)
    zweiter_spieltag = GameDay.create!(league: zweite_liga, arena: @arena, club: @club,
                                       number: 1, date: '2026-03-07')
    zweites_heim = create(:team, league: zweite_liga, club: @club, stream_key: STREAM_KEY)
    Game.create!(game_day: zweiter_spieltag, home_team: zweites_heim,
                 guest_team: create(:team, league: zweite_liga, club: create(:club)),
                 start_time: '18:00', forfait: 0, overtime: false, legacy: false,
                 game_status: 'match_record_closed',
                 events: [], players: { 'home' => [], 'guest' => [] })
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    api = api_mit(status: 'inactive')
    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert_nil StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).game_id
    assert(ergebnis[:notes].any? { |n| n.include?('mehrere Spieltage') })
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
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID)
                   .update!(last_active_at: @now - 30.minutes)

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
    assert(ergebnis[:problems].any? { |p| p.include?('Beenden von') })
  end

  # --- Der Schlüssel gehört dem Ausrichter ----------------------------------

  test 'ordnet über den Ausrichter zu, auch wenn dieser nicht die Heimmannschaft ist' do
    # Ein Verein richtet einen Spieltag aus, in dem er selbst nicht spielt --
    # gesendet wird trotzdem über seinen Schlüssel, denn er stellt die Halle.
    gast_a = create(:team, league: @league, club: create(:club))
    gast_b = create(:team, league: @league, club: create(:club))
    fremdes_spiel = Game.create!(game_day: @game_day, home_team: gast_a, guest_team: gast_b,
                                 start_time: '19:00', forfait: 0, overtime: false, legacy: false,
                                 game_status: 'match_record_closed',
                                 events: [], players: { 'home' => [], 'guest' => [] })
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.completed
    satz = StreamBroadcast.find_by(broadcast_id: BROADCAST_ID)
    assert_equal fremdes_spiel.id, satz.game_id,
                 'zugeordnet wird das jüngste Spiel des ausgerichteten Spieltags'
  end

  test 'GEGENPROBE: Heimmannschaft mit Schlüssel, aber ein anderer Verein richtet aus' do
    # Auswärts gespielt: Die Mannschaft trägt den Schlüssel, sendet aber nicht --
    # die Technik steht in der fremden Halle. Ihr Schlüssel darf dieses Spiel
    # nicht einfangen.
    fremder_spieltag = GameDay.create!(league: @league, arena: @arena, club: create(:club),
                                       number: 2, date: '2026-03-07')
    Game.create!(game_day: fremder_spieltag, home_team: @home, guest_team: @guest,
                 start_time: '18:00', forfait: 0, overtime: false, legacy: false,
                 game_status: 'match_record_closed',
                 events: [], players: { 'home' => [], 'guest' => [] })
    @game.destroy!
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert_nil StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).game_id
  end

  test 'ein Ausrichter mit mehreren Partien: Übergabe zur nächsten, Abschaltung erst nach der letzten' do
    @game.update!(game_status: 'match_record_closed')
    zweites = spiel_anlegen('20:10')

    # 20:00 -- die erste Partie ist durch, die zweite beginnt in zehn Minuten.
    satz_anlegen(signal_lost_at: nil)
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).update!(game_id: @game.id)
    api = api_mit(status: 'active')
    StreamWatchdog.new(api: api, now: @now).run
    assert_equal [BROADCAST_ID], api.completed, 'die laufende Übertragung muss den Schlüssel freigeben'

    # Für die zweite Partie wird eine EIGENE Übertragung angelegt -- ein
    # beendeter Satz wird bewusst nicht wiederbelebt, sonst ginge der Beleg
    # verloren, warum unwiderruflich abgeschaltet wurde.
    StreamBroadcast.create!(broadcast_id: 'bc-2', stream_id: STREAM_ID,
                            title: 'Zweite Partie', game_id: zweites.id,
                            last_active_at: @now, signal_lost_at: nil)

    # 22:30 -- auch die zweite ist durch, Bericht geschlossen, kein Signal mehr.
    zweites.update!(game_status: 'match_record_closed')
    spaeter = Time.zone.parse('2026-03-07 22:30:00 +01:00')
    StreamBroadcast.find_by(broadcast_id: 'bc-2').update!(signal_lost_at: spaeter - 20.minutes)

    api2 = FakeApi.new(
      broadcasts: [{ id: 'bc-2', title: 'Zweite Partie', stream_id: STREAM_ID }],
      streams: { STREAM_ID => { status: 'inactive', key: STREAM_KEY } }
    )
    StreamWatchdog.new(api: api2, now: spaeter).run

    assert_equal ['bc-2'], api2.completed
    satz = StreamBroadcast.find_by(broadcast_id: 'bc-2')
    assert_equal zweites.id, satz.game_id
    assert_match(/Spielbericht geschlossen/, satz.ended_reason)
  end

  test 'ein Spielverbund richtet über einen seiner Vereine aus' do
    ausrichtender_verein = create(:club)
    create(:team, league: @league, club: create(:club), stream_key: 'verbund-key',
                  syndicate: true, syndicate_clubs: [ausrichtender_verein.id])
    verbund_spieltag = GameDay.create!(league: @league, arena: @arena, club: ausrichtender_verein,
                                       number: 3, date: '2026-03-07')
    # Bewusst NICHT die Heimmannschaft: Sonst fände der alte Weg über das
    # Heimteam das Spiel ebenfalls, und der Verbundspfad wäre nicht belegt.
    verbund_spiel = Game.create!(game_day: verbund_spieltag,
                                 home_team: create(:team, league: @league, club: create(:club)),
                                 guest_team: @guest,
                                 start_time: '18:00', forfait: 0, overtime: false, legacy: false,
                                 game_status: 'match_record_closed',
                                 events: [], players: { 'home' => [], 'guest' => [] })
    StreamBroadcast.create!(broadcast_id: 'bc-verbund', stream_id: 'stream-verbund',
                            title: 'Verbund', signal_lost_at: @now - 20.minutes)

    api = FakeApi.new(
      broadcasts: [{ id: 'bc-verbund', title: 'Verbund', stream_id: 'stream-verbund' }],
      streams: { 'stream-verbund' => { status: 'inactive', key: 'verbund-key' } }
    )
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal ['bc-verbund'], api.completed
    assert_equal verbund_spiel.id, StreamBroadcast.find_by(broadcast_id: 'bc-verbund').game_id
  end

  # --- Der Übergabepfad darf nicht verstummen ---------------------------------

  # DER GEFÄHRLICHSTE ZUSTAND: Läuft die alte Übertragung mit Signal weiter und
  # bleibt ihr Bericht offen, während die nächste Partie längst angepfiffen ist,
  # gab es weder Übergabe noch Notabschaltung (deren Timer läuft nur bei
  # Signalverlust) noch irgendeine Meldung. Der Schlüssel war dauerhaft belegt,
  # und niemand erfuhr davon.
  test 'meldet, wenn die nächste Partie längst läuft und noch gesendet wird' do
    spiel_anlegen('19:00')
    satz_anlegen(signal_lost_at: nil)
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).update!(game_id: @game.id)

    api = api_mit(status: 'active')
    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert(ergebnis[:problems].any? { |p| p.include?('läuft seit') },
           'ein überfälliger Anwurf muss gemeldet werden, nicht verstummen')
  end

  # Der Vorlauf-Schutz hing allein an `spiel`; ohne bekannte Zuordnung und bei
  # kurzem Signalausfall schaltete die Übergabe die Übertragung ab, die zur
  # gleich beginnenden Partie gehört.
  test 'übergibt nicht, wenn gar kein Spiel zugeordnet ist' do
    @home.update!(stream_key: nil)
    spiel_anlegen('20:10')
    satz_anlegen(signal_lost_at: @now - 2.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
  end

  # Ein Ausrichter mit Heimspieltag am Samstag UND am Sonntag ist in der
  # Bundesliga der Regelfall. Die Mehrdeutigkeitsprüfung vor dem Zeitfilter
  # sperrte damit die Zuordnung den ganzen Sonntag.
  test 'ein Spieltag am Vortag sperrt die Zuordnung des heutigen nicht' do
    gestern = GameDay.create!(league: @league, arena: @arena, club: @club,
                              number: 9, date: '2026-03-06')
    Game.create!(game_day: gestern, home_team: @home, guest_team: @guest,
                 start_time: '18:00', forfait: 0, overtime: false, legacy: false,
                 game_status: 'match_record_closed',
                 events: [], players: { 'home' => [], 'guest' => [] })
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.completed
    assert_equal @game.id, StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).game_id
  end

  # Der Grenzwert der Notabschaltung war nach unten offen: Zwischen 20 Minuten
  # und drei Stunden lag kein Prüfsatz.
  test 'GEGENPROBE: zwei Stunden 59 Minuten lösen die Notabschaltung nicht aus' do
    satz_anlegen(signal_lost_at: @now - 3.hours + 1.second)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
  end

  # Die Transition zu `complete` ist bei YouTube nicht sofort sichtbar, der
  # nächste Lauf kommt aber in fünf Minuten. Ohne Karenz erzeugte JEDE saubere
  # Abschaltung ein Sentry-Ereignis und eine Cron-Fehlermail.
  test 'eine eben beendete Übertragung meldet noch kein Problem' do
    satz_anlegen(signal_lost_at: nil)
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID)
                   .update!(ended_at: @now - 1.minute, ended_reason: 'Spielbericht geschlossen')

    api = api_mit(status: 'active')
    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_empty ergebnis[:problems]
    assert(ergebnis[:notes].any? { |n| n.include?('eben beendet') })
  end

  # Der Beleg, WARUM unwiderruflich abgeschaltet wurde, ist das Einzige, was
  # nach einem Fehlgriff bleibt. `beende` schreibt ihn vor `complete!` -- die
  # Buchhaltung darf ihn danach nicht übermalen.
  test 'die Buchhaltung überschreibt einen vorhandenen Beendigungsgrund nicht' do
    StreamBroadcast.create!(broadcast_id: 'bc-halb', stream_id: STREAM_ID,
                            title: 'Halb beendet',
                            ended_reason: 'Spielbericht geschlossen, seit 20 min kein Signal',
                            last_active_at: @now - 1.hour)

    StreamWatchdog.new(api: FakeApi.new, now: @now).run

    satz = StreamBroadcast.find_by(broadcast_id: 'bc-halb')
    assert_equal 'Spielbericht geschlossen, seit 20 min kein Signal', satz.ended_reason
  end

  # Ohne obere Schranke bliebe eine Übertragung, deren aktiven Zustand der
  # Wächter nie erwischt hat (Cron-Ausfall, Deploy, sehr kurze Sendung), für
  # immer als laufend stehen.
  test 'ein Satz ohne je gesehenes Signal wird nach der Notfrist geschlossen' do
    StreamBroadcast.create!(broadcast_id: 'bc-nie', stream_id: STREAM_ID,
                            title: 'Nie gesehen', created_at: @now - 4.hours)

    StreamWatchdog.new(api: FakeApi.new, now: @now).run

    assert StreamBroadcast.find_by(broadcast_id: 'bc-nie').ended?
  end

  # --- Grenzwerte ------------------------------------------------------------

  # `.round` machte aus der dokumentierten Regel "seit 15 Minuten" faktisch
  # "seit 14 Minuten 30". Diese beiden Prüfsätze frieren die Regel auf die
  # Sekunde ein.
  test 'genau 15 Minuten ohne Signal beenden' do
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 15.minutes)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.completed
  end

  test 'GEGENPROBE: 14 Minuten 59 Sekunden beenden nicht' do
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: @now - 15.minutes + 1.second)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
  end

  test 'genau drei Stunden lösen die Notabschaltung aus' do
    satz_anlegen(signal_lost_at: @now - 3.hours)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.completed
  end

  # Der erste Lauf nach einem Signalabriss setzt nur den Timer. Ohne diesen
  # Prüfsatz käme ein Umbau auf `signal_lost_at || last_active_at` unbemerkt
  # durch und beendete beim ersten Aussetzer -- der teuerste denkbare Fehlgriff.
  test 'der erste Signalverlust startet nur den Timer' do
    @game.update!(game_status: 'match_record_closed')
    satz_anlegen(signal_lost_at: nil)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert_equal @now.to_i,
                 StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).signal_lost_at.to_i
  end

  # --- Die gemeldete Zuordnung schlägt die Heuristik ---------------------------

  test 'eine gemeldete Spielzuordnung wird nicht durch die Heuristik ersetzt' do
    fremdes = Game.create!(game_day: @game_day, home_team: @guest, guest_team: @home,
                           start_time: '19:00', forfait: 0, overtime: false, legacy: false,
                           game_status: 'match_record_closed',
                           events: [], players: { 'home' => [], 'guest' => [] })
    satz_anlegen(signal_lost_at: @now - 20.minutes)
    # Gemeldet ist das 18:00-Spiel; die Heuristik fände das jüngere 19:00-Spiel.
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).update!(game_id: @game.id)
    @game.update!(game_status: 'pregame')

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed, 'der gemeldete Spielbericht ist offen -- nicht beenden'
    assert_equal @game.id, StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).game_id
    assert_not_nil fremdes
  end

  test 'eine gemeldete Zuordnung wird nicht mit nil überschrieben' do
    @home.update!(stream_key: nil)
    satz_anlegen(signal_lost_at: @now - 5.minutes)
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).update!(game_id: @game.id)

    api = api_mit(status: 'inactive')
    StreamWatchdog.new(api: api, now: @now).run

    assert_equal @game.id, StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).game_id
  end

  # Fehlt bei einer Partie des Spieltags die Anwurfzeit, wäre "das jüngste Spiel
  # mit Anwurf" womöglich das vorherige -- mit geschlossenem Bericht, während die
  # Übertragung des laufenden sendet.
  test 'eine Partie ohne Anwurfzeit sperrt die Zuordnung des ganzen Spieltags' do
    @game.update!(game_status: 'match_record_closed')
    Game.create!(game_day: @game_day, home_team: @guest, guest_team: @home,
                 start_time: '', forfait: 0, overtime: false, legacy: false,
                 events: [], players: { 'home' => [], 'guest' => [] })
    satz_anlegen(signal_lost_at: @now - 20.minutes)

    api = api_mit(status: 'inactive')
    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert(ergebnis[:notes].any? { |n| n.include?('ohne Anwurfzeit') })
  end

  # --- Buchhaltung -------------------------------------------------------------

  # Eine im Voraus angelegte Übertragung ist bei YouTube `ready`, nicht `active`.
  # Ohne diesen Riegel bekäme sie fünf Minuten später ein `ended_at` und stünde
  # im Streaming-Bereich als "beendet", bevor sie je gelaufen ist.
  test 'eine im Voraus gemeldete Übertragung wird nicht als beendet gestempelt' do
    StreamBroadcast.create!(broadcast_id: 'bc-geplant', stream_id: STREAM_ID,
                            title: 'Nächste Woche', game_id: @game.id)

    StreamWatchdog.new(api: FakeApi.new, now: @now).run

    assert_not StreamBroadcast.find_by(broadcast_id: 'bc-geplant').ended?
  end

  test 'eine gerade noch sendende Übertragung wird nicht sofort abgeschlossen' do
    satz_anlegen(signal_lost_at: nil)
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).update!(last_active_at: @now - 1.minute)

    StreamWatchdog.new(api: FakeApi.new, now: @now).run

    assert_not StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).ended?,
               'eine einmalige Leerantwort darf keine laufenden Sätze abräumen'
  end

  test 'der Probelauf schreibt auch nichts in die Buchhaltung' do
    satz_anlegen(signal_lost_at: @now - 5.minutes)
    StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).update!(last_active_at: @now - 30.minutes)

    StreamWatchdog.new(api: FakeApi.new, dry_run: true, now: @now).run

    assert_not StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).ended?
  end

  # `ended_reason` ist der einzige Beleg dafür, warum unwiderruflich abgeschaltet
  # wurde. Die Transition ist bei YouTube nicht sofort sichtbar -- der nächste
  # Lauf darf ihn nicht überschreiben.
  test 'ein selbst beendeter Satz wird nicht wiederbelebt' do
    satz_anlegen(signal_lost_at: nil)
    satz = StreamBroadcast.find_by(broadcast_id: BROADCAST_ID)
    satz.update!(ended_at: @now - 1.hour, ended_reason: 'Spielbericht geschlossen, seit 20 min kein Signal')

    api = api_mit(status: 'active')
    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_equal 'Spielbericht geschlossen, seit 20 min kein Signal', satz.reload.ended_reason
    assert(ergebnis[:problems].any? { |p| p.include?('läuft bei YouTube aber wieder') })
  end

  # Ein Stream, dessen Zustand die Schnittstelle nicht liefert, ist nicht "ohne
  # Signal" -- über ihn ist nichts bekannt. Daraus abzuschalten hiesse, auf
  # Unwissen hin unwiderruflich zu handeln.
  test 'ein Stream ohne abrufbaren Zustand startet keinen Timer, meldet aber' do
    satz_anlegen(signal_lost_at: nil)
    api = FakeApi.new(
      broadcasts: [{ id: BROADCAST_ID, title: 'Heim vs Gast', stream_id: STREAM_ID }],
      streams: {}
    )

    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.completed
    assert_nil StreamBroadcast.find_by(broadcast_id: BROADCAST_ID).signal_lost_at
    # Gemeldet wird EINMAL, über die Sammelmeldung -- nicht zusätzlich je
    # Übertragung, sonst steht im Bericht die doppelte Zahl.
    assert_equal 1, ergebnis[:problems].size
    assert(ergebnis[:problems].any? { |p| p.include?('kein Zustand zurück') })
    assert(ergebnis[:notes].any? { |n| n.include?('Zustand nicht abrufbar') })
  end

  # --- Zusage an den Ausrichter: nach dem Spiel oeffentlich -------------------
  #
  # Ein paar Vereine senden ihr Heimspiel selbst und haben zugesagt bekommen,
  # dass unsere Uebertragung waehrenddessen nicht gelistet laeuft. Danach soll
  # die Aufzeichnung oeffentlich auf dem Verbandskanal stehen -- sonst ist die
  # halbe Zusage eine ganze Loeschung.

  test 'veroeffentlicht eine faellige Uebertragung und verlinkt sie im Spielplan' do
    satz = zusage_satz(ended_at: @now - StreamWatchdog::PROMOTE_DELAY - 1.minute)
    api = FakeApi.new

    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_equal [BROADCAST_ID], api.published
    assert_equal @now.to_i, satz.reload.promoted_at.to_i
    assert_equal "https://www.youtube.com/watch?v=#{BROADCAST_ID}", @game.reload.live_stream_link
    assert_equal 1, ergebnis[:published].size
  end

  # Der Verein sendet nach dem Schlusspfiff weiter -- Interviews, Abmoderation.
  # Waehrenddessen darf unsere Aufzeichnung nicht oeffentlich danebenstehen.
  test 'GEGENPROBE: vor Ablauf der Frist bleibt sie nicht gelistet' do
    satz = zusage_satz(ended_at: @now - StreamWatchdog::PROMOTE_DELAY + 1.minute)
    api = FakeApi.new

    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.published
    assert_nil satz.reload.promoted_at
    assert_nil @game.reload.live_stream_link
  end

  # Ohne den Riegel wuerde jede aus einem anderen Grund nicht gelistete
  # Aufzeichnung -- Probelauf, interne Aufnahme -- oeffentlich, und das ist
  # nicht zurueckzunehmen.
  test 'GEGENPROBE: ohne Zusage wird nichts veroeffentlicht' do
    satz = zusage_satz(ended_at: @now - 1.day, promote_to_public: false)
    api = FakeApi.new

    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.published
    assert_nil satz.reload.promoted_at
  end

  test 'GEGENPROBE: eine noch laufende Uebertragung wird nicht veroeffentlicht' do
    satz = zusage_satz(ended_at: nil)
    api = FakeApi.new

    StreamWatchdog.new(api: api, now: @now).run

    assert_empty api.published
    assert_nil satz.reload.promoted_at
  end

  test 'im Probelauf wird nichts veroeffentlicht' do
    satz = zusage_satz(ended_at: @now - 1.day)
    api = FakeApi.new

    ergebnis = StreamWatchdog.new(api: api, now: @now, dry_run: true).run

    assert_empty api.published
    assert_nil satz.reload.promoted_at
    assert(ergebnis[:notes].any? { |n| n.include?('wuerde veroeffentlichen') })
  end

  # Ein bereits gesetzter Link ist von Hand gepflegt oder von einem frueheren
  # Lauf -- ihn zu ueberschreiben nimmt dem Spielplan eine bewusste Eintragung.
  test 'ein vorhandener Link im Spielplan bleibt stehen' do
    @game.update!(live_stream_link: 'https://example.org/eigener-stream')
    zusage_satz(ended_at: @now - 1.day)

    StreamWatchdog.new(api: FakeApi.new, now: @now).run

    assert_equal 'https://example.org/eigener-stream', @game.reload.live_stream_link
  end

  # Die Uebertragung gibt es nicht mehr. Abgehakt wird sie trotzdem, sonst laeuft
  # der Cronjob alle fuenf Minuten in dieselbe leere Antwort -- verlinkt wird
  # aber nichts, der Link zeigte ins Leere.
  test 'eine verschwundene Uebertragung wird abgehakt, aber nicht verlinkt' do
    satz = zusage_satz(ended_at: @now - 1.day)
    api = FakeApi.new(publish_result: :verschwunden)

    StreamWatchdog.new(api: api, now: @now).run

    assert_not_nil satz.reload.promoted_at
    assert_nil @game.reload.live_stream_link
  end

  # Kein Stempel bei einem voruebergehenden Fehler: Der naechste Lauf soll es
  # erneut versuchen. Gemeldet wird er trotzdem -- eine still nicht eingeloeste
  # Zusage faellt sonst niemandem auf.
  test 'ein Fehler beim Veroeffentlichen wird gemeldet und nicht abgehakt' do
    satz = zusage_satz(ended_at: @now - 1.day)
    api = FakeApi.new(publish_error: YoutubeLiveApi::TransportError.new('Netz weg'))

    ergebnis = StreamWatchdog.new(api: api, now: @now).run

    assert_nil satz.reload.promoted_at
    assert(ergebnis[:problems].any? { |p| p.include?('Veroeffentlichung fehlgeschlagen') })
  end

  private

  def zusage_satz(ended_at:, promote_to_public: true)
    StreamBroadcast.create!(broadcast_id: BROADCAST_ID, stream_id: STREAM_ID,
                            title: 'Heim vs Gast', game: @game,
                            ended_at: ended_at, promote_to_public: promote_to_public)
  end

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
