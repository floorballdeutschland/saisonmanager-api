# frozen_string_literal: true

require 'test_helper'

class LegacyImport::HomeClubBackfillTest < ActiveSupport::TestCase # rubocop:disable Style/ClassAndModuleChildren
  BACKFILL = LegacyImport::HomeClubBackfill

  def candidate(id: 1, first_name: 'Max', gender: nil, active: true, clubless: false, current: nil, last: :same)
    { id:, first_name:, gender:, active:, clubless:,
      current_home_club_id: current, last_home_club_id: last == :same ? current : last }
  end

  def decide(first_name: 'Max', last_name: 'Muster', gender: nil, **kwargs)
    BACKFILL.decide(player: { first_name:, last_name:, gender: }, **kwargs)
  end

  # ── Vornamens-Klassifikation ──────────────────────────────────────────────

  test 'Vornamens-Abweichungen werden korrekt eingeordnet' do
    assert_equal 'identisch', BACKFILL.grade('Yara-Pauline', 'Yara Pauline')
    assert_equal 'identisch', BACKFILL.grade('André', 'Andre')
    assert_equal 'vertauscht', BACKFILL.grade('Per Flemming', 'Flemming Per')
    assert_equal 'teilmenge', BACKFILL.grade('Lisa', 'Lisa Katharina')
    assert_equal 'abkuerzung', BACKFILL.grade('Mark Oli', 'Mark-Oliver')
    assert_equal 'teiltreffer', BACKFILL.grade('Anna Lena', 'Anna Sophie Berta')
    assert_equal 'abweichend', BACKFILL.grade('Kathrin', 'Anna')
    assert_equal 'leer', BACKFILL.grade('', 'Anna')
  end

  test 'Umlaute werden gefaltet, nicht zerlegt' do
    assert_equal 'vaino', BACKFILL.fold('Väinö')
    assert_equal 'oelgemoller', BACKFILL.fold('Oelgemöller')
    assert_equal %w[mark oliver], BACKFILL.tokens('Mark-Oliver')
  end

  test 'ß fällt mit ss zusammen' do
    assert_equal BACKFILL.fold('Huss'), BACKFILL.fold('Huß')
    assert_equal 'identisch', BACKFILL.grade('Huß', 'Huss')
  end

  test 'die einbuchstabige Umlaut-Faltung trifft ae/oe/ue NICHT (bewusste Grenze)' do
    assert_not_equal BACKFILL.fold('Gruen'), BACKFILL.fold('Grün')
  end

  test 'ein einzelner Initial gilt nicht als Kürzung' do
    assert_equal 'abweichend', BACKFILL.grade('Anna', 'A')
    assert_equal 'abweichend', BACKFILL.grade('Anna Lena', 'A L')
  end

  test 'eine Kürzung mit nur einem Zeichen Unterschied bleibt ein Treffer' do
    # Bewusst zugelassen: der Task führt nichts zusammen, über die Identität
    # entscheidet der Verein. Siehe MIN_ABBREVIATION_LENGTH.
    assert_equal 'abkuerzung', BACKFILL.grade('Timm', 'Timmy')
    assert_equal 'abkuerzung', BACKFILL.grade('Jan', 'Jana')
  end

  # ── Vorname und Geschlecht als Filter ─────────────────────────────────────

  test 'nur die vier akzeptierten Schreibweisen gelten als Dublette' do
    assert_equal %w[identisch vertauscht teilmenge abkuerzung], BACKFILL::ACCEPTED_GRADES
  end

  test 'teiltreffer gilt NICHT als Dublette' do
    result = decide(first_name: 'Anna Lena',
                    candidates: [candidate(id: 5, first_name: 'Anna Sophie Berta', current: 42)],
                    license_club_ids: [128])

    assert_equal 'E', result[:group]
    assert_equal 128, result[:club_id]
  end

  test 'ein leerer Vorname gilt NICHT als Dublette' do
    result = decide(first_name: '',
                    candidates: [candidate(id: 5, first_name: 'Anna', current: 42)],
                    license_club_ids: [128])

    assert_equal 'E', result[:group]
  end

  test 'abweichender Vorname ist keine Dublette (Geschwister mit gleichem Geburtsdatum)' do
    result = decide(first_name: 'Kathrin',
                    candidates: [candidate(id: 5, first_name: 'Anna', current: 42)],
                    license_club_ids: [128])

    assert_equal 'E', result[:group]
    assert_equal 128, result[:club_id]
  end

  test 'bekanntes, abweichendes Geschlecht schließt einen Namenstreffer aus' do
    result = decide(first_name: 'Jan', gender: 'M',
                    candidates: [candidate(id: 5, first_name: 'Jana', gender: 'W', current: 42)],
                    license_club_ids: [128])

    assert_equal 'E', result[:group], 'Zwillinge trennt das Geschlecht'
    assert_equal 128, result[:club_id]
  end

  test 'Geschlecht wird case-insensitiv verglichen' do
    result = decide(first_name: 'Max', gender: 'M',
                    candidates: [candidate(id: 5, first_name: 'Max', gender: 'm', current: 42)],
                    license_club_ids: [128])

    assert_equal 'A', result[:group]
  end

  test 'unbekanntes Geschlecht auf einer Seite schließt nicht aus' do
    result = decide(first_name: 'Max', gender: nil,
                    candidates: [candidate(id: 5, first_name: 'Max', gender: 'W', current: 42)],
                    license_club_ids: [128])

    assert_equal 'A', result[:group]
  end

  # ── Priorität der Zuordnung ───────────────────────────────────────────────

  test 'A: eindeutige aktive Dublette schlägt den Lizenz-Verein' do
    # Fall: Vornamen vertauscht, und der heutige Verein der Dublette ist nicht der
    # Verein aus den Lizenzen. Für einen Merge muss beides im selben Konto liegen.
    result = decide(first_name: 'Per Flemming',
                    candidates: [candidate(id: 5, first_name: 'Flemming Per', current: 81)],
                    license_club_ids: [7])

    assert_equal 'A', result[:group]
    assert_equal 81, result[:club_id]
    assert_equal 5, result[:candidate_id]
  end

  test 'A: mehrdeutige Lizenz-Vereine sind irrelevant, sobald eine Dublette existiert' do
    result = decide(first_name: 'Lisa',
                    candidates: [candidate(id: 5, first_name: 'Lisa Katharina', current: 62)],
                    license_club_ids: [62, 76, 147, 159, 108])

    assert_equal 'A', result[:group]
    assert_equal 62, result[:club_id]
  end

  test 'A: mehrere aktive Dubletten im SELBEN Verein sind eindeutig' do
    # Genau die Population, die der Verein zusammenführen soll.
    result = decide(candidates: [candidate(id: 5, current: 42), candidate(id: 6, current: 42)],
                    license_club_ids: [128])

    assert_equal 'A', result[:group]
    assert_equal 42, result[:club_id]
  end

  test 'A nutzt den gültigen, nicht den letzten bekannten Heimatverein' do
    result = decide(candidates: [candidate(id: 5, current: 81, last: 42)])

    assert_equal 'A', result[:group]
    assert_equal 81, result[:club_id]
  end

  test 'B: aktive Dubletten in verschiedenen Vereinen werden übersprungen' do
    result = decide(candidates: [candidate(id: 5, current: 48), candidate(id: 6, current: 180)],
                    license_club_ids: [48])

    assert_equal 'B', result[:group]
    assert_nil result[:club_id]
    assert_match(/2 verschiedenen Vereinen/, result[:reason])
  end

  test 'M: aktive Dublette ohne gültige Heimatmitgliedschaft blockiert' do
    # Ihr Heimateintrag ist geschlossen, sie steht damit selbst nicht über einen
    # Heimateintrag in Club#players und wäre kein Merge-Partner.
    result = decide(candidates: [candidate(id: 5, current: nil, last: 42)],
                    license_club_ids: [7])

    assert_equal 'M', result[:group]
    assert_nil result[:club_id]
    assert_match(/ohne gültige Heimatmitgliedschaft/, result[:reason])
  end

  test 'C: deaktivierte Dubletten in verschiedenen Vereinen werden übersprungen' do
    result = decide(candidates: [candidate(id: 5, active: false, current: nil, last: 48),
                                 candidate(id: 6, active: false, current: nil, last: 180)],
                    license_club_ids: [7])

    assert_equal 'C', result[:group]
    assert_nil result[:club_id], 'widersprüchliche Belege dürfen nicht in den Lizenz-Zweig durchfallen'
  end

  test 'D: deaktivierte Dublette liefert den letzten bekannten Verein' do
    result = decide(first_name: 'Mark Oli',
                    candidates: [candidate(id: 5, first_name: 'Mark-Oliver', active: false, current: nil, last: 82)],
                    license_club_ids: [3])

    assert_equal 'D', result[:group]
    assert_equal 82, result[:club_id]
    assert_equal 5, result[:candidate_id]
  end

  test 'D: mehrere deaktivierte Dubletten im selben Verein sind eindeutig' do
    result = decide(candidates: [candidate(id: 5, active: false, current: nil, last: 82),
                                 candidate(id: 6, active: false, current: nil, last: 82)])

    assert_equal 'D', result[:group]
    assert_equal 82, result[:club_id]
  end

  test 'E: ohne Dublette entscheidet der eindeutige Lizenz-Verein' do
    result = decide(license_club_ids: [128])

    assert_equal 'E', result[:group]
    assert_equal 128, result[:club_id]
  end

  test 'F: ohne Dublette und mit mehreren Lizenz-Vereinen wird übersprungen' do
    result = decide(license_club_ids: [76, 147])

    assert_equal 'F', result[:group]
    assert_nil result[:club_id]
    assert_match(/2 Lizenz-Vereine/, result[:reason])
  end

  test 'G: ohne Lizenz und ohne Dublette wird übersprungen' do
    result = decide

    assert_equal 'G', result[:group]
    assert_nil result[:club_id]
    assert_match(/keine belegende Lizenz/, result[:reason])
  end

  test 'I: vereinsloser Partner nutzt den Lizenz-Verein, damit beide im selben Konto landen' do
    result = decide(candidates: [candidate(id: 30, clubless: true, current: nil)],
                    license_club_ids: [126])

    assert_equal 'I', result[:group]
    assert_equal 126, result[:club_id]
    assert_match(/Partner ohne Verein: 30/, result[:reason])
  end

  test 'I nennt alle vereinslosen Partner' do
    result = decide(candidates: [candidate(id: 30, clubless: true), candidate(id: 31, clubless: true)],
                    license_club_ids: [126])

    assert_match(/Partner ohne Verein: 30,31/, result[:reason])
  end

  test 'J: vereinsloser Partner mit mehrdeutigem Lizenz-Verein wird übersprungen' do
    result = decide(candidates: [candidate(id: 30, clubless: true)], license_club_ids: [126, 202])

    assert_equal 'J', result[:group]
    assert_nil result[:club_id]
    assert_match(/2 Lizenz-Vereine/, result[:reason])
  end

  test 'J sagt nicht mehrdeutig, wenn es überhaupt keine Lizenz gibt' do
    result = decide(candidates: [candidate(id: 30, clubless: true)], license_club_ids: [])

    assert_equal 'J', result[:group]
    assert_match(/keine belegende Lizenz/, result[:reason])
  end

  test 'K: fehlendes Geburtsdatum schreibt nichts, auch nicht über die Lizenz' do
    result = decide(license_club_ids: [128], birthdate_known: false)

    assert_equal 'K', result[:group]
    assert_nil result[:club_id], 'ohne Abgleich darf kein Verein gesetzt werden'
    assert_match(/nicht möglich/, result[:reason])
  end

  test 'L: nicht auflösbares Lizenz-Team blockiert, statt Eindeutigkeit vorzutäuschen' do
    result = decide(license_club_ids: [128], unresolved_license_teams: 1)

    assert_equal 'L', result[:group]
    assert_nil result[:club_id]
    assert_match(/ohne Verein/, result[:reason])
  end

  # ── Platzhalter- und deaktivierte Vereine ─────────────────────────────────

  test 'H: Dublette nur in einem Ablage-Verein blockiert' do
    result = decide(candidates: [candidate(id: 5, current: 88)],
                    license_club_ids: [194], ignore_club_ids: [88])

    assert_equal 'H', result[:group]
    assert_nil result[:club_id]
  end

  test 'Platzhalter-Verein wird auch als Lizenz-Verein verworfen' do
    result = decide(license_club_ids: [107], ignore_club_ids: [107])

    assert_equal 'G', result[:group]
    assert_nil result[:club_id]
  end

  test 'ein Lizenz-Verein bleibt, wenn nur EINER der beiden ignoriert wird' do
    result = decide(license_club_ids: [107, 194], ignore_club_ids: [107])

    assert_equal 'E', result[:group]
    assert_equal 194, result[:club_id]
  end

  # ── Eintrag ───────────────────────────────────────────────────────────────

  test 'build_entry erzeugt einen OFFENEN Heimateintrag mit Marker' do
    entry = BACKFILL.build_entry(club_id: 128, created_at: '2010-09-04T16:27:33')

    assert_equal 128, entry['club_id']
    assert entry['home_club']
    assert_nil entry['valid_until'], 'valid_until muss leer bleiben, sonst fehlt das Profil in Club#players'
    assert_equal '2010-09-04T16:27:33', entry['created_at']
    assert_equal BACKFILL::SOURCE, entry['source']
  end

  test 'build_entry fällt ohne Belegzeitpunkt auf den Zeitpunkt des Laufs zurück' do
    travel_to Time.zone.parse('2026-07-30 12:00:00') do
      assert_equal Time.current.iso8601, BACKFILL.build_entry(club_id: 81)['created_at']
    end
  end

  test 'build_entry setzt kein created_by und kein valid_set_by' do
    # Player#membership_closed_by_deactivation? – die Logik hinter reactivate! und der
    # VM-Spielerliste – erkennt geschlossene Zugehörigkeiten an valid_until zum
    # Deaktivierungszeitpunkt plus valid_set_by == deactivated_by; gesetzte Felder
    # würden den Eintrag dort hineinziehen. Ohne valid_until greift sie ohnehin nicht.
    entry = BACKFILL.build_entry(club_id: 128)

    assert_not entry.key?('created_by')
    assert_not entry.key?('valid_set_by')
  end

  # ── Idempotenz und Rücknahme ──────────────────────────────────────────────

  test 'apply schreibt in ein leeres clubs-Array' do
    entry = BACKFILL.build_entry(club_id: 128)
    new_clubs, status = BACKFILL.apply([], entry)

    assert_equal :written, status
    assert_equal [entry], new_clubs
  end

  test 'apply ist idempotent: zweiter Lauf mit gleichem Verein ändert nichts' do
    entry = BACKFILL.build_entry(club_id: 128, created_at: '2010-09-04T16:27:33')
    once, = BACKFILL.apply([], entry)
    twice, status = BACKFILL.apply(once, entry)

    assert_equal :unchanged, status
    assert_equal once, twice
  end

  test 'apply korrigiert einen eigenen Alt-Eintrag mit anderem Verein' do
    old = BACKFILL.build_entry(club_id: 128)
    new_clubs, status = BACKFILL.apply([old], BACKFILL.build_entry(club_id: 81))
    club_ids = new_clubs.map { |c| c['club_id'] }

    assert_equal :written, status
    assert_equal [81], club_ids
  end

  test 'apply fasst einen eigenen, von Hand geschlossenen Eintrag nicht wieder an' do
    closed = BACKFILL.build_entry(club_id: 128).merge('valid_until' => '2026-07-30T00:00:00+02:00')
    new_clubs, status = BACKFILL.apply([closed], BACKFILL.build_entry(club_id: 128))

    assert_equal :closed_by_hand, status
    assert_equal [closed], new_clubs, 'eine menschliche Entscheidung darf nicht überschrieben werden'
  end

  test 'apply legt mehrere eigene Alt-Einträge auf einen zusammen' do
    old = [BACKFILL.build_entry(club_id: 128), BACKFILL.build_entry(club_id: 129)]
    new_clubs, status = BACKFILL.apply(old, BACKFILL.build_entry(club_id: 81))

    assert_equal :written, status
    assert_equal 1, new_clubs.size
  end

  test 'apply lässt fremde Einträge unangetastet und schreibt gar nicht' do
    foreign = { 'club_id' => 42, 'home_club' => true }
    new_clubs, status = BACKFILL.apply([foreign], BACKFILL.build_entry(club_id: 128))

    assert_equal :foreign_entry, status
    assert_equal [foreign], new_clubs
  end

  test 'apply reicht die Eingabe-Hashes nicht durch (kein Alias auf fremde Einträge)' do
    foreign = { 'club_id' => 42, 'home_club' => true }
    new_clubs, = BACKFILL.apply([foreign], BACKFILL.build_entry(club_id: 128))
    new_clubs.first['club_id'] = 999

    assert_equal 42, foreign['club_id'], 'der Aufrufer darf seine eigenen Hashes unverändert wiederfinden'
  end

  test 'revert entfernt nur die eigenen Einträge und meldet sie zurück' do
    real = { 'club_id' => 42, 'home_club' => true }
    own = BACKFILL.build_entry(club_id: 128)
    kept, removed = BACKFILL.revert([real, own])

    assert_equal [real], kept
    assert_equal [own], removed
  end

  test 'revert meldet nichts, wenn kein eigener Eintrag vorliegt' do
    kept, removed = BACKFILL.revert([{ 'club_id' => 42 }])

    assert_empty removed
    assert_equal [{ 'club_id' => 42 }], kept
  end

  test 'revert reicht die Eingabe-Hashes nicht durch' do
    real = { 'club_id' => 42, 'home_club' => true }
    kept, = BACKFILL.revert([real, BACKFILL.build_entry(club_id: 128)])
    kept.first['club_id'] = 999

    assert_equal 42, real['club_id']
  end
end
