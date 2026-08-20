require 'test_helper'

# Setting ist Singleton (`Setting.first`); die Factory ersetzt vorhandene
# Setting-Zeilen pro Test. Tests hier decken die Symptome aus PR #168 ab —
# `current_min_team`-Fallback auf 0, wenn `min_team_id` in der Saison fehlt.
class SettingTest < ActiveSupport::TestCase
  # Ein Treffer im Rails-Cache ist hier nicht gratis: der MemoryStore macht bei
  # jedem Lesen ein Marshal.load des ganzen AR-Objekts samt JSONB-Spalten. Bei
  # 75 Aufrufstellen war das auf Produktion der groesste Einzelposten der
  # Lizenzliste des Verbandes. Die anfrage-lokale Ebene davor muss daher greifen.
  # Gegenprobe ueber Setting.first, weil Rails.cache im Test :null_store ist —
  # ohne die Memoisierung landet jeder Aufruf dort in der Datenbank.
  test 'current liest die Konfiguration nur einmal je Vorgang' do
    create(:setting)
    Setting.current # Zwischenspeicher fuellen

    reads = 0
    counting_load = lambda do
      reads += 1
      Setting.unscoped.take
    end
    Setting.stub(:first, counting_load) do
      3.times { Setting.current }
    end

    assert_equal 0, reads, 'Setting.current darf innerhalb eines Vorgangs nicht erneut laden'
  end

  test 'flush_current_cache verwirft den anfrage-lokalen Zwischenspeicher' do
    create(:setting, current_season_id: 18)
    assert_equal 18, Setting.current_season_id

    # update_columns umgeht die Callbacks, raeumt also nicht selbst ab.
    Setting.first.update_columns(systems: { '1' => { 'current_season_id' => 17 } })
    Setting.flush_current_cache

    assert_equal 17, Setting.current_season_id
  end

  # Der after_commit-Hook muss beide Ebenen treffen, nicht nur den Rails-Cache.
  test 'ein Speichern verwirft den Zwischenspeicher' do
    create(:setting, current_season_id: 18)
    assert_equal 18, Setting.current_season_id

    Setting.first.update!(systems: { '1' => { 'current_season_id' => 17 } })

    assert_equal 17, Setting.current_season_id
  end

  test 'current_season_id liest aus systems["1"]["current_season_id"]' do
    create(:setting, current_season_id: 18)

    assert_equal 18, Setting.current_season_id
  end

  # Auf Produktion trug Saison 17 noch ein gespeichertes `current: true`, während
  # die aktive Saison 18 war. Ein solches Flag darf die aktive Saison nie
  # beeinflussen — maßgeblich ist ausschließlich systems["1"]["current_season_id"].
  test 'ein gespeichertes current-Flag im seasons-Hash aendert die aktive Saison nicht' do
    setting = create(:setting, current_season_id: 18)
    setting.update_columns(
      seasons: setting.seasons.merge('17' => setting.seasons['17'].merge('current' => true))
    )

    assert_equal 18, Setting.current_season_id
    assert_equal 18, Setting.seasons.find { |s| s[:current] }[:id],
                 'Setting.seasons muss current aus current_season_id berechnen, nicht aus dem Hash lesen'
  end

  # Gegenprobe zur Migration RemoveStaleCurrentFlagFromSeasons: Neu angelegte
  # Saisons dürfen das Flag nicht wieder einführen.
  test 'seasons-Eintraege tragen kein gespeichertes current-Flag' do
    create(:setting, current_season_id: 18)

    assert(Setting.current.seasons.values.none? { |s| s.key?('current') },
           'seasons darf kein gespeichertes current-Flag enthalten')
  end

  test 'current_season_id reagiert auf andere Saison-Werte' do
    create(:setting, current_season_id: 17)

    assert_equal 17, Setting.current_season_id
  end

  test 'current_min_team liefert gesetzten Wert' do
    create(:setting, current_season_id: '18', current_min_team: 1500)

    assert_equal 1500, Setting.current_min_team
  end

  test 'current_min_team ohne min_team_id-Eintrag → 0 (Bonner-Bug aus PR #168)' do
    # Ohne explizites min_team_id für die aktuelle Saison fällt
    # Setting.current_min_team auf 0 zurück. Das ist exakt der Pfad, der die
    # Vorsaison-Lizenzen weiterhin als „aktuell" durchließ.
    create(:setting, current_season_id: '18', current_min_team: nil)

    assert_equal 0, Setting.current_min_team
  end

  test 'current_min_league ohne Wert → 0 (analoges Verhalten)' do
    create(:setting, current_season_id: '18', current_min_league: nil)

    assert_equal 0, Setting.current_min_league
  end

  test 'current_min_league liefert gesetzten Wert' do
    create(:setting, current_season_id: '18', current_min_league: 4200)

    assert_equal 4200, Setting.current_min_league
  end

  test 'league_class liefert den Namen zum Code' do
    create(:setting, league_classes: { 'rl' => { 'name' => 'Regionalliga' } })

    assert_equal 'Regionalliga', Setting.league_class('rl')
  end

  test 'league_class liefert für unbekannte Keys und fehlende Map leeren String (kein Crash, #297)' do
    create(:setting, league_classes: { 'rl' => { 'name' => 'Regionalliga' } })
    assert_equal '', Setting.league_class('30')
    assert_equal '', Setting.league_class(nil)

    Setting.first.update_columns(league_classes: nil)
    Setting.flush_current_cache
    assert_equal '', Setting.league_class('rl')
  end

  test 'seasons liefert sortierte Liste mit current-Markierung' do
    create(:setting, current_season_id: '18')

    seasons = Setting.seasons
    assert_kind_of Array, seasons
    refute_empty seasons
    current_entries = seasons.select { |s| s[:current] }
    assert_equal 1, current_entries.size
    assert_equal 18, current_entries.first[:id]
  end

  # ---------------------------------------------------------------------------
  # Formsicherheit der seasons-Leser. Je nach Altbestand steht unter einer Saison
  # ein Hash mit 'name' oder ein blanker String, und beide Fehlformen scheitern
  # LEISE: `entry['name']` auf einem String sucht einen Teilstring und liefert nil,
  # ein fehlender Key wirft NoMethodError. Hinter deliver_later fällt beides
  # niemandem auf.
  # ---------------------------------------------------------------------------

  test 'season_name liest den Namen aus einem Hash-Eintrag' do
    create(:setting)

    assert_equal 'Saison 2025/26', Setting.season_name('18')
  end

  test 'season_name liest einen blanken String als Namen' do
    create(:setting, seasons: { '18' => 'Saison 2025/26' })

    assert_equal 'Saison 2025/26', Setting.season_name('18')
  end

  test 'season_name ist nil bei unbekannter Saison, leerem Namen und leerer Eingabe' do
    create(:setting, seasons: { '18' => { 'name' => '' } })

    assert_nil Setting.season_name('18'), 'leerer Name zählt nicht als Name'
    assert_nil Setting.season_name('99'), 'unbekannte Saison darf nicht werfen'
    assert_nil Setting.season_name(nil)
    assert_nil Setting.season_name('')
  end

  test 'seasons_hash faengt eine seasons-Spalte ab, die gar kein Hash ist' do
    create(:setting)
    Setting.first.update_columns(seasons: nil)
    Setting.flush_current_cache

    assert_empty Setting.seasons_hash
    assert_nil Setting.season_name('18')
    assert_equal [], Setting.seasons
  end

  test 'seasons benennt auch einen Eintrag, der als blanker String vorliegt' do
    create(:setting, current_season_id: '18', seasons: { '18' => 'Saison 2025/26' })

    entry = Setting.seasons.find { |s| s[:id] == 18 }
    assert_equal 'Saison 2025/26', entry[:name],
                 'sonst zeigt der Saison-Umschalter einen namenlosen Eintrag'
  end

  test 'current_season_start_year liest das Jahr auch aus einem blanken String' do
    create(:setting, current_season_id: '18', seasons: { '18' => 'Saison 2026/2027' })

    assert_equal 2026, Setting.current_season_start_year
  end

  # Der Fallback schätzt mit August-Grenze. Ohne festes Datum prüft ein Test dieses
  # Zweigs von August bis Dezember nichts, weil die Schätzung dann zufällig
  # dasselbe Jahr liefert wie ein korrekt gelesener Name.
  test 'current_season_start_year schaetzt mit August-Grenze, wenn kein Jahr im Namen steht' do
    create(:setting, current_season_id: '18', seasons: { '18' => 'Saison 26/27' })

    travel_to Date.new(2026, 9, 1) do
      assert_equal 2026, Setting.current_season_start_year
    end
    travel_to Date.new(2026, 3, 1) do
      assert_equal 2025, Setting.current_season_start_year,
                   'vor August gehoert der Stichtag zur vorigen Saison'
    end
  end

  # ---------------------------------------------------------------------------
  # season_start_year: die Jahresextraktion. `split('/').first` verlangt, dass der
  # Name mit den Ziffern beginnt, und ergibt bei „Saison 2026/27" eine 0 — genau
  # der Fehler, der die Lizenz-Gueltigkeit ein Jahr zu kurz machte.
  # ---------------------------------------------------------------------------

  test 'season_start_year liest das Jahr in allen vorkommenden Schreibweisen' do
    {
      '2026/2027' => 2026,
      '2026/27' => 2026,
      'Saison 2026/27' => 2026,
      'Saison 2026/2027' => 2026
    }.each do |name, expected|
      create(:setting, current_season_id: '18', seasons: { '18' => { 'name' => name } })
      assert_equal expected, Setting.season_start_year('18'), "Schreibweise #{name.inspect}"
    end
  end

  test 'season_start_year ist nil ohne Jahreszahl, ohne Eintrag und ohne Eingabe' do
    create(:setting, current_season_id: '18', seasons: { '18' => { 'name' => 'Saison 26/27' } })

    assert_nil Setting.season_start_year('18')
    assert_nil Setting.season_start_year('99')
    assert_nil Setting.season_start_year(nil)
  end

  # ---------------------------------------------------------------------------
  # current_season liefert immer einen Hash. Sonst lesen current_min_team und
  # current_min_league `['min_team_id']` auf einem String, bekommen still nil und
  # verschlucken es im `|| 0`. Der 0-Fallback ist der dokumentierte Weg fuer einen
  # FEHLENDEN Schluessel (#168), nicht fuer eine Fehlform.
  # ---------------------------------------------------------------------------

  test 'current_season ist auch bei einem blanken String ein Hash' do
    create(:setting, current_season_id: '18', seasons: { '18' => 'Saison 2025/26' })

    assert_equal({}, Setting.current_season)
  end

  test 'min_team und min_league brechen bei kaputter seasons-Spalte nicht ab' do
    create(:setting)
    Setting.first.update_columns(seasons: nil)
    Setting.flush_current_cache

    assert_equal 0, Setting.current_min_team
    assert_equal 0, Setting.current_min_league
  end

  # point_corrections hängt an League#table, also an jeder öffentlichen
  # Ligaseite. Zwei Ebenen können krumm sein, und die zweite ist die
  # realistischere: die Spalte hat einen Default, der Eintrag pro Liga entsteht
  # per Konsolen-Korrektur.
  test 'point_corrections faengt eine Spalte ab, die kein Hash ist' do
    create(:setting)
    Setting.first.update_columns(point_corrections: nil)
    Setting.flush_current_cache

    assert_nil Setting.point_corrections(1)
  end

  test 'point_corrections faengt einen Liga-Eintrag mit falscher Form ab' do
    create(:setting)

    # Array: ergab in League#table einen TypeError, also einen 500er auf der
    # öffentlichen Ligaseite.
    Setting.first.update_columns(point_corrections: { '1' => [] })
    Setting.flush_current_cache
    assert_nil Setting.point_corrections(1)

    # String: rechnete dort still ohne den Abzug weiter.
    Setting.first.update_columns(point_corrections: { '1' => 'minus 3' })
    Setting.flush_current_cache
    assert_nil Setting.point_corrections(1)
  end

  test 'point_corrections liefert einen korrekten Eintrag unveraendert' do
    create(:setting, point_corrections: { '1' => { '7' => -3 } })

    assert_equal({ '7' => -3 }, Setting.point_corrections(1))
  end
end
