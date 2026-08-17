require 'test_helper'

class TeamTest < ActiveSupport::TestCase
  test 'current_season enthält nur Teams der aktuellen Saison, nicht Alt-Saisons' do
    create(:setting, current_season_id: '18')
    current = create(:team, league: create(:league, :current_season))
    # Alt-Saison mit (im Test) potenziell höherer league_id – früher per
    # ID-Schwelle fälschlich „aktuell", jetzt über season_id korrekt ausgeschlossen.
    archived = create(:team, league: create(:league, :archived_season))

    ids = Team.current_season.pluck(:id)
    assert_includes ids, current.id
    refute_includes ids, archived.id
  end

  # ---------------------------------------------------------------------------
  # Kuerzel: teams.short_name ist nullable, Reihenfolge Mannschaft > Verein > Name
  # ---------------------------------------------------------------------------

  test 'short_name darf hoechstens acht Zeichen haben' do
    team = build(:team, short_name: 'BW96 II')
    assert_predicate team, :valid?

    # Die dritte Mannschaft braucht drei Zeichen fuer die Nummer. Bei sieben
    # waere sie auf "BW96 II" gekappt worden und haette auf der Anzeigetafel wie
    # die zweite geheissen.
    team.short_name = 'BW96 III'
    assert_predicate team, :valid?

    team.short_name = 'BW96 IIII'
    assert_not team.valid?
    assert_includes team.errors.attribute_names, :short_name
  end

  # Bestandswerte sind laenger als die neue Grenze. Eine unbedingte Pruefung
  # haette jedes Speichern dieser Mannschaft blockiert, auch dort, wo das
  # Kuerzel gar nicht vorkommt: Ein Teammanager, der nur die
  # Feedback-Kontaktadresse setzt, waere an einer Meldung ueber ein Feld
  # haengengeblieben, das er nicht bearbeiten kann.
  test 'ein zu langer Bestandswert blockiert das Speichern anderer Felder nicht' do
    team = create(:team, short_name: 'SGK')
    team.update_column(:short_name, 'SG Kaufering / Geiselbullach')

    team.reload
    assert team.update(contact_email: 'neu@example.org'), team.errors.full_messages.join(', ')
    assert_equal 'neu@example.org', team.reload.contact_email
    assert_equal 'SG Kaufering / Geiselbullach', team.short_name, 'der Wert bleibt, bis er geaendert wird'
  end

  test 'wer den Bestandswert anfasst, muss die Grenze einhalten' do
    team = create(:team, short_name: 'SGK')
    team.update_column(:short_name, 'SG Kaufering / Geiselbullach')

    team.reload
    assert_not team.update(short_name: 'immer noch zu lang')
    assert_includes team.errors.attribute_names, :short_name
  end

  test 'ticker_hash nutzt das hinterlegte Kuerzel' do
    team = create(:team, name: 'Floorball Musterstadt', short_name: 'FBMS')

    assert_equal 'FBMS', team.ticker_hash[:shortName]
  end

  # Frueher schnitt `.split(' ').first` alles nach dem ersten Wort ab: Die
  # zweite Mannschaft hiess auf der Anzeigetafel wie die erste.
  test 'ticker_hash behaelt die roemische Nummer der zweiten Mannschaft' do
    team = create(:team, short_name: 'BW96 II')

    assert_equal 'BW96 II', team.ticker_hash[:shortName]
  end

  test 'ticker_hash kappt ein zu langes Kuerzel bei acht Zeichen' do
    # Bestandswerte sind laenger als die neue Grenze; die Validierung greift
    # erst beim naechsten Speichern, die Anzeige muss sofort passen.
    team = create(:team, short_name: 'SGK')
    team.update_column(:short_name, 'SG Kaufering')

    assert_equal 'SG Kaufe', team.ticker_hash[:shortName]
  end

  test 'ticker_hash faellt ohne Kuerzel auf das Vereinskuerzel zurueck' do
    club = create(:club, name: 'TV Lilienthal', short_name: 'TVL')
    team = create(:team, name: 'Lilienthaler Woelfe', short_name: nil, club: club)

    assert_equal 'TVL', team.ticker_hash[:shortName]
  end

  test 'ticker_hash faellt ohne Kuerzel und ohne Vereinskuerzel auf den Namen zurueck' do
    # Ohne Rueckfall starb slice mit NoMethodError und riss die ganze
    # Ticker-Antwort der Liga mit.
    club = create(:club, short_name: nil)
    team = create(:team, name: 'Musterstadt', short_name: nil, club: club)

    assert_equal 'Musterst', team.ticker_hash[:shortName]
  end

  test 'ticker_hash behandelt ein leeres Kuerzel wie ein fehlendes' do
    club = create(:club, short_name: 'MUS')
    team = create(:team, name: 'Musterstadt', short_name: '', club: club)

    assert_equal 'MUS', team.ticker_hash[:shortName]
  end

  # ---------------------------------------------------------------------------
  # Elternzustimmung: welche Liga sie ausloest
  # ---------------------------------------------------------------------------

  test 'parental_consent_league ist nil, wenn keine Liga der Mannschaft sie verlangt' do
    team = create(:team, league: create(:league, :current_season))

    assert_nil team.parental_consent_league
  end

  test 'parental_consent_league findet die Pokal-Liga, wenn nur sie das Flag traegt' do
    team = create(:team, league: create(:league, :current_season))
    pokal = create(:league, :current_season, name: 'FD-Pokal', parental_consent_required: true)
    team.update!(cup_leagues: [pokal.id])

    assert_equal pokal.id, team.parental_consent_league.id
  end

  # Der default_scope von League sortiert nach season_id, game_operation_id und
  # order_key, nicht danach, welche Liga die Hauptliga ist. Ein blosses
  # `leagues.find(&:parental_consent_required)` nahm deshalb die Pokal-Liga, obwohl
  # die Hauptliga die Zustimmung genauso verlangt, und nannte der gesetzlichen
  # Vertretung eine Liga, um die es gar nicht ging.
  test 'parental_consent_league bevorzugt die Hauptliga vor der Pokal-Liga' do
    go = create(:game_operation)
    haupt = create(:league, :current_season, game_operation: go, name: 'Regionalliga Bayern',
                                             order_key: '2', parental_consent_required: true)
    pokal = create(:league, :current_season, game_operation: go, name: 'FD-Pokal',
                                             order_key: '1', parental_consent_required: true)
    team = create(:team, league: haupt)
    team.update!(cup_leagues: [pokal.id])

    assert_equal pokal.id, team.leagues.first.id,
                 'Vorbedingung: der default_scope stellt die Pokal-Liga nach vorn'
    assert_equal haupt.id, team.parental_consent_league.id
  end

  # ---------------------------------------------------------------------------
  # Expresslizenz: welche Liga sie erlaubt. Diese Liga bestimmt, welche SBK den
  # Antrag bekommt und welcher Verband die Zusatzkosten stellt.
  # ---------------------------------------------------------------------------

  test 'express_license_league ist nil, wenn keine Liga der Mannschaft sie erlaubt' do
    team = create(:team, league: express_ready_league(express: false))

    assert_nil team.express_license_league
  end

  test 'express_license_league findet die Pokal-Liga, wenn nur sie sie erlaubt' do
    team = create(:team, league: express_ready_league(express: false))
    pokal = express_ready_league(express: true, name: 'FD-Pokal')
    team.update!(cup_leagues: [pokal.id])

    assert_equal pokal.id, team.express_license_league.id
  end

  # Ohne Vorrang der Hauptliga entscheidet der default_scope von League, und weil
  # der zuerst nach season_id sortiert, gewinnt sogar ein Alt-Eintrag in
  # cup_leagues aus einer vergangenen Saison. Der Antrag ginge dann an die SBK
  # eines Verbands, mit dem die Mannschaft in dieser Saison nichts zu tun hat.
  test 'express_license_league bevorzugt die Hauptliga vor der Pokal-Liga' do
    haupt = express_ready_league(express: true, name: 'Regionalliga Bayern')
    pokal = express_ready_league(express: true, name: 'Alt-Pokal', season_id: '17')
    team = create(:team, league: haupt)
    team.update!(cup_leagues: [pokal.id])

    assert_equal pokal.id, team.leagues.first.id,
                 'Vorbedingung: der default_scope stellt die Alt-Saison nach vorn'
    assert_equal haupt.id, team.express_license_league.id
  end

  # Das Zeitfenster gehoert zur Liga (League#express_license_window_open?): erlaubt
  # der Verband die Expresslizenz, ist das Fenster dieser Liga aber noch zu, darf sie
  # nicht gewaehlt werden. Sonst kombinierte die Auswahl die Erlaubnis der einen mit
  # dem Fenster einer anderen Liga.
  test 'express_license_league ueberspringt eine Liga mit geschlossenem Zeitfenster' do
    haupt = express_ready_league(express: true, days_ahead: 30)
    pokal = express_ready_league(express: true, name: 'FD-Pokal')
    team = create(:team, league: haupt)
    team.update!(cup_leagues: [pokal.id])

    assert_equal pokal.id, team.express_license_league.id
  end

  private

  # Liga, deren Verband die Expresslizenz erlaubt (oder eben nicht) und deren erster
  # Spieltag im Fenster liegt. Beides muss zusammenkommen, sonst ist
  # League#express_license_possible? unabhaengig von der Auswahl schon false.
  def express_ready_league(express:, name: nil, season_id: '18', days_ahead: 1)
    sa = create(:state_association, express_license_enabled: express)
    attrs = { game_operation: create(:game_operation, state_association: sa), season_id: season_id }
    attrs[:name] = name if name
    league = create(:league, **attrs)
    create(:game_day, league: league, date: (Date.current + days_ahead).to_s)
    league
  end
end
