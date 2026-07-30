# frozen_string_literal: true

require 'test_helper'

class LegacyImport::HomeClubBackfillTest < ActiveSupport::TestCase # rubocop:disable Style/ClassAndModuleChildren
  BACKFILL = LegacyImport::HomeClubBackfill

  def candidate(id: 1, first_name: 'Max', active: true, legacy: false, current: nil, last: nil)
    { id:, first_name:, active:, legacy:, current_home_club_id: current, last_home_club_id: last || current }
  end

  def decide(first_name: 'Max', last_name: 'Muster', **kwargs)
    BACKFILL.decide(player: { first_name:, last_name: }, **kwargs)
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

  test 'Umlaute und ß werden gefaltet, nicht zerlegt' do
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

  # ── Priorität der Zuordnung ───────────────────────────────────────────────

  test 'A: eindeutige aktive Dublette schlaegt den Lizenz-Verein' do
    # Per-Flemming-Kühl-Fall: Lizenzen sagen Verein 7, das lebende Profil steht
    # heute bei Verein 81. Für einen Merge muss beides im selben Konto liegen.
    result = decide(first_name: 'Per Flemming',
                    candidates: [candidate(id: 9020, first_name: 'Flemming Per', current: 81)],
                    license_club_ids: [7])

    assert_equal 'A', result[:group]
    assert_equal 81, result[:club_id]
    assert_equal 9020, result[:candidate_id]
  end

  test 'A: mehrdeutige Lizenz-Vereine sind irrelevant, sobald eine Dublette existiert' do
    # Lisa-Feindt-Fall: fünf überlappende Lizenz-Vereine, aber ein lebendes Profil.
    result = decide(first_name: 'Lisa',
                    candidates: [candidate(id: 3209, first_name: 'Lisa Katharina', current: 62)],
                    license_club_ids: [62, 76, 147, 159, 108])

    assert_equal 'A', result[:group]
    assert_equal 62, result[:club_id]
  end

  test 'A: aktive Dublette ohne GUELTIGE Heimat zaehlt nicht als Ziel' do
    # Ihr Heimateintrag ist geschlossen, sie stünde selbst nicht in Club#players
    # und wäre im Duplikat-Dropdown nicht auswählbar.
    result = decide(candidates: [candidate(id: 5, current: nil, last: 42)],
                    license_club_ids: [7])

    assert_equal 'E', result[:group]
    assert_equal 7, result[:club_id]
  end

  test 'B: mehrere aktive Dubletten in verschiedenen Vereinen werden uebersprungen' do
    result = decide(first_name: 'Tim',
                    candidates: [candidate(id: 3681, first_name: 'Tim', current: 48),
                                 candidate(id: 9652, first_name: 'Tim', current: 180)],
                    license_club_ids: [48])

    assert_equal 'B', result[:group]
    assert_nil result[:club_id]
  end

  test 'D: deaktivierte Dublette liefert den letzten bekannten Verein' do
    # Mark-Oli-Bothe-Fall: Dublette am 16.07. deaktiviert, letzte Heimat Leipzig.
    result = decide(first_name: 'Mark Oli',
                    candidates: [candidate(id: 13915, first_name: 'Mark-Oliver', active: false, current: nil, last: 82)],
                    license_club_ids: [3])

    assert_equal 'D', result[:group]
    assert_equal 82, result[:club_id]
    assert_equal 13915, result[:candidate_id]
  end

  test 'E: ohne Dublette entscheidet der eindeutige Lizenz-Verein' do
    result = decide(license_club_ids: [128])

    assert_equal 'E', result[:group]
    assert_equal 128, result[:club_id]
  end

  test 'F: ohne Dublette und mit mehreren Lizenz-Vereinen wird uebersprungen' do
    result = decide(license_club_ids: [76, 147])

    assert_equal 'F', result[:group]
    assert_nil result[:club_id]
  end

  test 'G: ohne Lizenz und ohne Dublette wird uebersprungen' do
    result = decide

    assert_equal 'G', result[:group]
    assert_nil result[:club_id]
  end

  test 'I: Legacy-Paar nutzt den Lizenz-Verein, damit beide im selben Konto landen' do
    result = decide(first_name: 'Arthur',
                    candidates: [candidate(id: 30954, first_name: 'Arthur', legacy: true, current: nil)],
                    license_club_ids: [126])

    assert_equal 'I', result[:group]
    assert_equal 126, result[:club_id]
    assert_match(/Legacy-Paar mit 30954/, result[:reason])
  end

  test 'J: Legacy-Paar mit mehrdeutigem Lizenz-Verein wird uebersprungen' do
    result = decide(first_name: 'Arthur',
                    candidates: [candidate(id: 30954, first_name: 'Arthur', legacy: true)],
                    license_club_ids: [126, 202])

    assert_equal 'J', result[:group]
    assert_nil result[:club_id]
  end

  test 'abweichender Vorname ist keine Dublette (Geschwister mit gleichem Geburtsdatum)' do
    result = decide(first_name: 'Kathrin',
                    candidates: [candidate(id: 5992, first_name: 'Anna', current: 42)],
                    license_club_ids: [128])

    assert_equal 'E', result[:group]
    assert_equal 128, result[:club_id]
  end

  # ── Platzhalter-Vereine ───────────────────────────────────────────────────

  test 'Dublette in einem Ablage-Verein wird nicht als Ziel genommen' do
    result = decide(candidates: [candidate(id: 5, current: 88)],
                    license_club_ids: [194], ignore_club_ids: [88])

    assert_equal 'E', result[:group]
    assert_equal 194, result[:club_id]
    assert_match(/Ablage-Verein/, result[:reason])
  end

  test 'H: Dublette in Ablage-Verein und mehrdeutige Lizenz wird uebersprungen' do
    result = decide(candidates: [candidate(id: 5, current: 88)],
                    license_club_ids: [194, 195], ignore_club_ids: [88])

    assert_equal 'H', result[:group]
    assert_nil result[:club_id]
  end

  test 'Platzhalter-Verein wird auch als Lizenz-Verein verworfen' do
    result = decide(license_club_ids: [107], ignore_club_ids: [107])

    assert_equal 'G', result[:group]
    assert_nil result[:club_id]
  end

  # ── Eintrag, Idempotenz, Ruecknahme ───────────────────────────────────────

  test 'build_entry erzeugt einen OFFENEN Heimateintrag mit Marker' do
    entry = BACKFILL.build_entry(club_id: 128, created_at: '2010-09-04T16:27:33')

    assert_equal 128, entry['club_id']
    assert entry['home_club']
    assert_nil entry['valid_until'], 'valid_until muss leer bleiben, sonst fehlt das Profil in Club#players'
    assert_equal '2010-09-04T16:27:33', entry['created_at']
    assert_equal LegacyImport::HomeClubBackfill::SOURCE, entry['source']
  end

  test 'build_entry faellt ohne Belegzeitpunkt auf jetzt zurueck' do
    entry = BACKFILL.build_entry(club_id: 81)

    assert entry['created_at'].present?
  end

  test 'apply schreibt in ein leeres clubs-Array' do
    entry = BACKFILL.build_entry(club_id: 128)
    new_clubs, changed = BACKFILL.apply([], entry)

    assert changed
    assert_equal [entry], new_clubs
  end

  test 'apply ist idempotent: zweiter Lauf mit gleichem Verein aendert nichts' do
    entry = BACKFILL.build_entry(club_id: 128, created_at: '2010-09-04T16:27:33')
    once, = BACKFILL.apply([], entry)
    twice, changed = BACKFILL.apply(once, entry)

    assert_not changed
    assert_equal 1, twice.size
  end

  test 'apply korrigiert einen eigenen Alt-Eintrag mit anderem Verein' do
    old = BACKFILL.build_entry(club_id: 128)
    new_clubs, changed = BACKFILL.apply([old], BACKFILL.build_entry(club_id: 81))

    assert changed
    club_ids = new_clubs.map { |c| c['club_id'] }

    assert_equal [81], club_ids
  end

  test 'apply laesst fremde Eintraege unangetastet' do
    foreign = { 'club_id' => 42, 'home_club' => true }
    new_clubs, changed = BACKFILL.apply([foreign], BACKFILL.build_entry(club_id: 128))

    assert_not changed
    assert_equal [foreign], new_clubs
  end

  test 'apply mutiert das Eingabe-Array nicht' do
    original = [BACKFILL.build_entry(club_id: 128)]
    snapshot = Marshal.load(Marshal.dump(original))
    BACKFILL.apply(original, BACKFILL.build_entry(club_id: 81))

    assert_equal snapshot, original
  end

  test 'revert entfernt nur die eigenen Eintraege, auch neben echten' do
    real = { 'club_id' => 42, 'home_club' => true }
    own = BACKFILL.build_entry(club_id: 128)
    kept, changed = BACKFILL.revert([real, own])

    assert changed
    assert_equal [real], kept
  end

  test 'revert meldet keine Aenderung, wenn kein eigener Eintrag vorliegt' do
    kept, changed = BACKFILL.revert([{ 'club_id' => 42 }])

    assert_not changed
    assert_equal [{ 'club_id' => 42 }], kept
  end
end
