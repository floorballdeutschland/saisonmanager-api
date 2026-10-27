require 'test_helper'

# Sprungmarken zu den Toren in der Beschreibung der Aufzeichnung (api#815).
class StreamChaptersTest < ActiveSupport::TestCase
  # Ersetzt YoutubeLiveApi. Hält fest, was gelesen und geschrieben wurde.
  class FakeApi
    attr_reader :video_requests, :written
    attr_accessor :description

    def initialize(details: {}, description: "Livestream vom Spieltag\nKamera: Verein")
      @details = details
      @description = description
      @video_requests = []
      @written = []
    end

    def videos(ids)
      @video_requests << ids
      @details.slice(*ids)
    end

    def update_description!(video_id)
      neu = yield(@description)
      return :unveraendert if neu == @description

      @written << [video_id, neu]
      @description = neu
      :geschrieben
    end
  end

  BROADCAST_ID = 'bc-tore'.freeze

  setup do
    create(:setting)
    @start = Time.zone.parse('2026-10-11 17:50:00')
    @now = @start + 4.hours
    @game = create(:game, game_status: 'match_record_closed', started: true, tablet_capture_at: @start,
                          players: {
                            'home' => [lineup(7, 'Max', 'Müller'), lineup(9, 'Tom', 'Schmidt')],
                            'guest' => [lineup(11, 'Ben', 'Weber')]
                          })
    @broadcast = StreamBroadcast.create!(broadcast_id: BROADCAST_ID, game: @game, title: 'Heim vs Gast',
                                         last_active_at: @start + 2.hours, ended_at: @start + 2.hours + 20.minutes)
  end

  test 'schreibt Streamstart und je Tor eine Marke mit Vorlauf 120 s, Text bleibt erhalten' do
    tore([@start + 1152.seconds, 'home', 7, 9, 1, 0], [@start + 1482.seconds, 'guest', 11, nil, 1, 1])
    api = FakeApi.new(details: details)

    lauf(api)

    assert_equal 1, api.written.size
    _id, beschreibung = api.written.first
    assert beschreibung.start_with?("Livestream vom Spieltag\nKamera: Verein\n\n"), 'Text von Hand bleibt stehen'
    assert_includes beschreibung, "0:00 Streamstart\n17:12 1:0 Müller (Schmidt)\n22:42 1:1 Weber\n"
    @broadcast.reload
    assert_equal @start, @broadcast.actual_start_at
    assert_equal 7200, @broadcast.vod_duration_seconds
    assert @broadcast.chapters_digest.present?
    assert_equal @now.to_i, @broadcast.chapters_written_at.to_i
  end

  test 'ohne Tabletmodus keine Sprungmarken' do
    @game.update_columns(tablet_capture_at: nil)
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)

    assert_empty api.written
    assert_nil @broadcast.reload.chapters_written_at
  end

  test 'ohne Tabletmodus wird ein früher geschriebener Block entfernt' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)
    assert_includes api.description, StreamChapters::BLOCK_START

    @game.update_columns(tablet_capture_at: nil)
    lauf(api)

    assert_equal 2, api.written.size
    assert_equal "Livestream vom Spieltag\nKamera: Verein", api.description
    assert_nil @broadcast.reload.chapters_digest
  end

  test 'ohne Tabletmodus: ältere Aufzeichnung verliert den Block in der Nachrechnung, danach Ruhe' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)

    @game.update_columns(tablet_capture_at: nil)
    spaeter = @now + 30.days
    StreamChapters.new(api: api, now: spaeter).run

    assert_not_includes api.description, StreamChapters::BLOCK_START
    assert_equal spaeter.to_i, @broadcast.reload.chapters_checked_at.to_i

    StreamChapters.new(api: api, now: spaeter + 25.hours).run
    assert_equal 2, api.written.size, 'nach dem Entfernen kein weiterer Aufruf'
  end

  test 'Entfernen ist je 24 Stunden gedeckelt, der Rest folgt später' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)
    @game.update_columns(tablet_capture_at: nil)
    StreamBroadcast.insert_all(Array.new(StreamChapters::MAX_REMOVALS_PER_DAY) do |i|
      { broadcast_id: "entfernt-#{i}", chapters_written_at: @now - 1.hour, chapters_digest: nil }
    end)

    marken = lauf(api)
    assert_includes api.description, StreamChapters::BLOCK_START, 'Deckel erreicht: Block bleibt vorerst'
    assert(marken.notes.any? { |n| n.include?('Tagesdeckel') })

    StreamChapters.new(api: api, now: @now + 1.day).run
    assert_not_includes api.description, StreamChapters::BLOCK_START
  end

  test 'Probelauf meldet das Entfernen als Entfernen' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)
    @game.update_columns(tablet_capture_at: nil)

    marken = StreamChapters.new(api: api, now: @now, dry_run: true).run

    assert_equal 1, api.written.size
    assert(marken.notes.any? { |n| n.include?('würde Sprungmarken entfernen') })
  end

  test 'ein zweiter Lauf ohne Änderung schreibt nicht und fragt YouTube nicht erneut' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)
    lauf(api)

    assert_equal 1, api.written.size
    assert_equal 1, api.video_requests.size, 'Start und Länge liegen gespeichert vor'
  end

  test 'eine Korrektur ersetzt den Block, statt ihn zu verdoppeln' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)

    @game.events.first['home_number'] = 9
    @game.save!
    lauf(api)

    assert_equal 2, api.written.size
    beschreibung = api.description
    assert_equal 1, beschreibung.scan(StreamChapters::BLOCK_START).size
    assert_includes beschreibung, '17:12 1:0 Schmidt'
    assert_not_includes beschreibung, 'Müller'
  end

  test 'eine Kalibrierung verschiebt die Marken und schreibt den Block neu (fe#560)' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)
    assert_includes api.description, '17:12 1:0 Müller'

    @broadcast.reload.update!(offset_seconds: 20)
    lauf(api)

    assert_equal 2, api.written.size, 'geänderter Block, also neu geschrieben'
    assert_includes api.description, '17:32 1:0 Müller'
    assert_not_includes api.description, '17:12'
  end

  test 'vorgemerkte Szenen werden keine Sprungmarken (fe#560)' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    GameShot.create!(game: @game, client_uuid: 'm1', kind: 'mark', period: 1, tapped_at: @start + 30.minutes)
    api = FakeApi.new(details: details)
    lauf(api)

    assert_equal 1, api.description.scan(/^\d+:\d{2} /).size - 1, 'nur Streamstart und das Tor'
  end

  test 'Tore unter 10 s Abstand werden zu einer Marke zusammengelegt' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0], [@start + 1158.seconds, 'home', 9, nil, 2, 0],
         [@start + 3000.seconds, 'guest', 11, nil, 2, 1])
    api = FakeApi.new(details: details)
    lauf(api)

    assert_includes api.description, '17:12 1:0 Müller, 2:0 Schmidt'
  end

  test 'Tore außerhalb der Aufzeichnung (nach dem Ende des Bildes) fallen weg' do
    # VOD 2 h; das zweite Tor wurde 2 h 30 min nach Streamstart eingetragen.
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0], [@start + 9000.seconds, 'guest', 11, nil, 1, 1])
    api = FakeApi.new(details: details)
    lauf(api)

    assert_includes api.description, '17:12 1:0 Müller'
    assert_not_includes api.description, 'Weber'
  end

  test 'nachgetragener Bericht: alle Tore in wenigen Minuten eingetragen, keine Marken' do
    tore([@start + 1.hour, 'home', 7, nil, 1, 0], [@start + 1.hour + 40.seconds, 'home', 9, nil, 2, 0],
         [@start + 1.hour + 90.seconds, 'guest', 11, nil, 2, 1])
    api = FakeApi.new(details: details)
    lauf(api)

    assert_empty api.written
    assert_nil @broadcast.reload.chapters_digest
  end

  test 'der Nachname einer anonymisierten Person erscheint nicht' do
    spieler = create(:player, first_name: 'Max', last_name: 'Müller', public_last_name_hidden_at: Time.current)
    @game.players['home'][0]['player_id'] = spieler.id
    @game.save!
    PublicPlayerNames.flush!
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)

    assert_includes api.description, '17:12 1:0 Max'
    assert_not_includes api.description, 'Müller'
  end

  test 'offener Spielbericht: nichts wird gelesen oder geschrieben' do
    @game.update!(game_status: 'running')
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)

    assert_empty api.video_requests
    assert_empty api.written
  end

  test 'ohne fertige Aufzeichnung (P0D) wird nicht geschrieben und später erneut gefragt' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: { BROADCAST_ID => { actual_start_at: @start, duration_seconds: nil } })
    lauf(api)
    lauf(api)

    assert_empty api.written
    assert_equal 2, api.video_requests.size
  end

  test 'Probelauf schreibt weder bei YouTube noch in die Datenbank' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    marken = StreamChapters.new(api: api, dry_run: true, now: @now).run

    assert_empty api.written
    assert_nil @broadcast.reload.actual_start_at
    assert(marken.notes.any? { |n| n.include?('17:12 1:0 Müller') })
  end

  test 'ein vorübergehender Fehler beim Schreiben ist eine Notiz, der Stempel bleibt aus' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    api.define_singleton_method(:update_description!) { |_id| raise YoutubeLiveApi::TransportError, 'weg' }
    marken = lauf(api)

    assert_empty marken.probleme
    assert(marken.notes.any? { |n| n.include?('wird wiederholt') })
    assert_nil @broadcast.reload.chapters_digest
    assert_equal 1, @broadcast.chapters_attempts
  end

  test 'Strafen bekommen eine Marke mit Strafart, Name und Teamkürzel, Vorlauf 120 s' do
    mannschaften!
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    strafen([@start + 2170.seconds, 'guest', 11], [@start + 3000.seconds, 'home', 2001], [@start + 3500.seconds, 'home', 99])
    api = FakeApi.new(details: details)
    lauf(api)

    beschreibung = api.description
    assert_includes beschreibung, "17:12 1:0 Müller\n34:10 Strafe 2 Min. Weber (GAST)\n"
    assert_includes beschreibung, '48:00 Strafe 2 Min. Betreuer (HEIM)'
    assert_includes beschreibung, '56:20 Strafe 2 Min. (HEIM)', 'ohne Spieler im Bericht nur das Team'
  end

  test 'Tor und Strafe unter 10 s Abstand: eine Marke, Tor zuerst' do
    mannschaften!
    tore([@start + 1158.seconds, 'home', 7, nil, 1, 0])
    strafen([@start + 1152.seconds, 'guest', 11])
    api = FakeApi.new(details: details)
    lauf(api)

    assert_includes api.description, '17:12 1:0 Müller, Strafe 2 Min. Weber (GAST)'
  end

  test 'Nachtrag wird nur an Toren erkannt und nimmt dann auch die Strafen heraus' do
    # Viele Strafen in kurzer Zeit machen noch keinen Nachtrag.
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    strafen([@start + 2000.seconds, 'guest', 11], [@start + 2010.seconds, 'guest', 11],
            [@start + 2030.seconds, 'guest', 11])
    api = FakeApi.new(details: details)
    lauf(api)
    assert_equal 1, api.written.size

    tore([@start + 1.hour, 'home', 7, nil, 1, 0], [@start + 1.hour + 40.seconds, 'home', 9, nil, 2, 0],
         [@start + 1.hour + 90.seconds, 'guest', 11, nil, 2, 1])
    strafen([@start + 1.hour + 100.seconds, 'guest', 11])
    lauf(api)
    assert_not_includes api.description, StreamChapters::BLOCK_START, 'Block entfernt'
  end

  test 'Nachtrag erst bei kurzem mittlerem Abstand: drei Tore in vier Minuten bekommen Marken' do
    tore([@start + 1.hour, 'home', 7, nil, 1, 0], [@start + 1.hour + 2.minutes, 'home', 9, nil, 2, 0],
         [@start + 1.hour + 4.minutes, 'guest', 11, nil, 2, 1])
    api = FakeApi.new(details: details)
    lauf(api)

    assert_equal 1, api.written.size
  end

  # --- Fehler je Übertragung, Backoff (Review api#817) -------------------------

  test 'ein kaputtes Spiel hält die übrigen Übertragungen nicht auf' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    kaputt = create(:game, game_status: 'match_record_closed')
    StreamBroadcast.create!(broadcast_id: 'bc-kaputt', game: kaputt, last_active_at: @start,
                            ended_at: @broadcast.ended_at - 1.minute, actual_start_at: @start,
                            vod_duration_seconds: 7200)
    api = FakeApi.new(details: details)
    original = StreamChapters.method(:block_for)
    marken = nil
    StreamChapters.stub(:block_for, lambda { |game, broadcast|
      raise TypeError, 'kaputter Altdatensatz' if broadcast.broadcast_id == 'bc-kaputt'

      original.call(game, broadcast)
    }) do
      marken = lauf(api)
    end

    assert_equal [BROADCAST_ID], api.written.map(&:first)
    assert(marken.notes.any? { |n| n.include?('bc-kaputt') && n.include?('TypeError') })
  end

  test 'vorübergehende Fehler: zwei Notizen, beim dritten Versuch ein Problem, danach Ruhe' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    aufrufe = 0
    api.define_singleton_method(:update_description!) do |_id|
      aufrufe += 1
      raise YoutubeLiveApi::TransportError, 'Zeitüberschreitung'
    end

    ergebnisse = Array.new(4) { lauf(api) }

    assert_equal 3, aufrufe, 'nach dem dritten Fehlversuch wird nicht mehr gefragt'
    assert_equal [0, 0, 1, 0], ergebnisse.map { |m| m.probleme.size }, 'genau einmal gemeldet'
    assert @broadcast.reload.chapters_failed_at.present?
  end

  test 'eine 4xx-Antwort ist sofort endgültig, ein neuer Inhalt versucht es erneut' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    api.define_singleton_method(:update_description!) { |_id| raise YoutubeLiveApi::ClientError, '400 invalidDescription' }
    erste = lauf(api)
    assert_equal 1, erste.probleme.size
    assert_empty lauf(api).probleme

    api.singleton_class.send(:remove_method, :update_description!)
    @game.events.first['home_number'] = 9
    @game.save!
    lauf(api)
    assert_equal 1, api.written.size
  end

  test 'die Länge der Beschreibung zählt in Bytes' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details, description: 'ä' * 2450)
    marken = lauf(api)

    assert_empty api.written
    assert_equal 1, marken.probleme.size
    assert_match(/Bytes/, marken.probleme.first)
  end

  # --- Unbefristetes Nachrechnen beschriebener Aufzeichnungen (DSGVO) ------------

  test 'nach Ablauf der Frist wird eine beschriebene Aufzeichnung täglich nachgerechnet' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    lauf(api)
    assert_includes api.description, 'Müller'

    spieler = create(:player, public_last_name_hidden_at: Time.current)
    @game.players['home'][0]['player_id'] = spieler.id
    @game.save!
    PublicPlayerNames.flush!

    spaeter = @now + 30.days
    StreamChapters.new(api: api, now: spaeter).run
    assert_not_includes api.description, 'Müller', 'Anonymisierung schlägt auch nach 30 Tagen durch'
    assert_equal spaeter.to_i, @broadcast.reload.chapters_checked_at.to_i

    # Am selben Tag nicht noch einmal: ein erneuter Wechsel wartet bis morgen.
    @game.players['home'][0]['player_name'] = 'Neu'
    @game.players['home'][0]['player_id'] = nil
    @game.save!
    StreamChapters.new(api: api, now: spaeter + 1.hour).run
    assert_equal 2, api.written.size
    StreamChapters.new(api: api, now: spaeter + 25.hours).run
    assert_equal 3, api.written.size
  end

  test 'nie beschriebene Aufzeichnungen bleiben nach Ablauf der Frist unberührt' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    StreamChapters.new(api: api, now: @now + 30.days).run

    assert_empty api.video_requests
    assert_empty api.written
  end

  test 'Kalibrierung nach Ablauf der Frist: nächster Lauf schreibt, auch ohne bisherigen Block (fe#560)' do
    tore([@start + 1152.seconds, 'home', 7, nil, 1, 0])
    api = FakeApi.new(details: details)
    spaeter = @now + 30.days
    StreamChapters.new(api: api, now: spaeter).run
    assert_empty api.written, 'unkalibriert und nie beschrieben: unberührt'

    @broadcast.update!(offset_seconds: 20, calibrated_at: spaeter, calibrated_via: 'link', chapters_checked_at: nil)
    StreamChapters.new(api: api, now: spaeter + 5.minutes).run

    assert_equal 1, api.written.size
    assert_includes api.description, '17:32 1:0 Müller', 'Marke um den Versatz verschoben'
  end

  test 'der Editor setzt die Nachrechnung zurück' do
    @broadcast.update!(actual_start_at: @start, vod_duration_seconds: 7200, chapters_checked_at: @now)
    @game.update_columns(live_stream_link: "https://www.youtube.com/watch?v=#{BROADCAST_ID}",
                         tablet_capture_at: @start)
    GameShot.create!(game: @game, client_uuid: 'm1', kind: 'mark', period: 1, tapped_at: @start + 20.minutes)

    HighlightEditor.new(@game).update!({ offset_seconds: 15 })

    assert_nil @broadcast.reload.chapters_checked_at
  end

  test 'beschreibung_mit ersetzt nur den Block und lässt Text davor und danach stehen' do
    alt = "Oben\n\n#{StreamChapters::BLOCK_START}\n0:00 Streamstart\n#{StreamChapters::BLOCK_END}\nUnten"
    neu = StreamChapters.beschreibung_mit(alt, "#{StreamChapters::BLOCK_START}\nX\n#{StreamChapters::BLOCK_END}")

    assert_includes neu, 'Oben'
    assert_includes neu, 'Unten'
    assert_includes neu, "\nX\n"
    assert_not_includes neu, 'Streamstart'
  end

  test 'Zeitformat ab einer Stunde mit Stunden' do
    assert_equal '0:00', StreamTimeline.timestamp(0)
    assert_equal '17:12', StreamTimeline.timestamp(1032)
    assert_equal '1:02:03', StreamTimeline.timestamp(3723)
  end

  private

  def lauf(api)
    StreamChapters.new(api: api, now: @now).run
  end

  def details
    { BROADCAST_ID => { actual_start_at: @start, duration_seconds: 7200 } }
  end

  def lineup(number, first, last)
    { 'trikot_number' => number, 'player_firstname' => first, 'player_name' => last }
  end

  def mannschaften!
    liga = @game.game_day.league
    @game.update!(home_team: create(:team, league: liga, short_name: 'HEIM'),
                  guest_team: create(:team, league: liga, short_name: 'GAST'))
  end

  # [added_at, Team, Nummer]: zwei Minuten, an die vorhandenen Tore angehängt.
  def strafen(*liste)
    basis = @game.events.size
    @game.events += liste.each_with_index.map do |(zeit, team, nummer), i|
      { 'id' => basis + i + 1, 'event_type' => 'penalty', 'event_team' => team, 'period' => 1,
        'time' => '30:00', "#{team}_number" => nummer, 'penalty_id' => 1, 'penalty_code_id' => 1,
        'penalty_name' => '2 Min.', 'added_at' => zeit.to_i }
    end
    @game.save!
  end

  # [added_at, Team, Schütze, Vorlage, Heimtore, Gasttore]
  def tore(*liste)
    @game.events = liste.each_with_index.map do |(zeit, team, nummer, vorlage, heim, gast), i|
      event = { 'id' => i + 1, 'event_type' => 'goal', 'event_team' => team, 'period' => 1,
                'time' => format('%02d:00', i + 1), 'home_goals' => heim, 'guest_goals' => gast,
                'added_at' => zeit.to_i }
      event["#{team}_number"] = nummer
      event["#{team}_assist"] = vorlage if vorlage
      event
    end
    @game.save!
  end
end
