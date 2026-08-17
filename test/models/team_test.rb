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

  # cup_leagues ist ein Integer-Array ohne Fremdschluessel und ohne
  # Saisonbindung: Ein Eintrag aus einer abgeschlossenen Saison bleibt stehen, bis
  # ihn jemand entfernt. Er darf die Zustimmungspflicht fuer einen Antrag der
  # laufenden Saison nicht ausloesen, sonst verweist die Art.-13-Mail auf einen
  # Verband, mit dem die Mannschaft in dieser Saison nichts zu tun hat.
  test 'parental_consent_league ignoriert eine Pokal-Liga aus fremder Saison' do
    haupt = create(:league, :current_season, name: 'Regionalliga Bayern')
    alt = create(:league, :previous_season, name: 'Alt-Pokal', parental_consent_required: true)
    team = create(:team, league: haupt)
    team.update!(cup_leagues: [alt.id])

    assert_equal alt.id, team.leagues.first.id,
                 'Vorbedingung: der default_scope stellt die Alt-Saison nach vorn'
    assert_nil team.parental_consent_league
  end

  # Gegenprobe zum Filter: Eine Pokal-Liga DERSELBEN Saison bleibt zustaendig,
  # auch wenn die Hauptliga die Zustimmung nicht verlangt. Der Filter darf nur
  # fremde Saisons treffen.
  test 'parental_consent_league nimmt die Pokal-Liga derselben Saison' do
    haupt = create(:league, :current_season, name: 'Regionalliga Bayern')
    pokal = create(:league, :current_season, name: 'FD-Pokal', parental_consent_required: true)
    team = create(:team, league: haupt)
    team.update!(cup_leagues: [pokal.id])

    assert_equal pokal.id, team.parental_consent_league.id
  end

  # Ohne Hauptliga fehlt der Anker fuer den Saisonvergleich. teams.league_id ist
  # nullable, der Fremdschluessel aus #293 schliesst nur den Verweis ins Leere.
  test 'parental_consent_league ist nil, wenn die Mannschaft keine Hauptliga hat' do
    pokal = create(:league, :current_season, parental_consent_required: true)
    team = create(:team, league: create(:league, :current_season))
    team.update!(cup_leagues: [pokal.id])
    team.update_columns(league_id: nil)

    assert_nil team.reload.parental_consent_league
  end

  # Die Zustimmungspflicht der Hauptliga darf nicht an ihrer season_id haengen:
  # Das Feld hat mit der Zustimmung nichts zu tun. Ein frueherer Entwurf pruefte
  # den Saisonanker VOR der Hauptliga und lieferte hier nil, obwohl die Hauptliga
  # das Flag selbst traegt — eine Lizenz waere dann ohne die verlangte Zustimmung
  # erteilt worden. season_id traegt `validates presence`, die Spalte ist aber
  # nullable und Altdaten-Importe sind hier historisch der Grund fuer solche Werte.
  test 'parental_consent_league nennt die Hauptliga auch ohne lesbare Saison' do
    haupt = create(:league, :current_season, name: 'Regionalliga Bayern', parental_consent_required: true)
    team = create(:team, league: haupt)
    haupt.update_columns(season_id: nil)

    assert_equal haupt.id, team.reload.parental_consent_league&.id
  end

  # season_leagues ist die gemeinsame Grundlage fuer die Zustimmungspflicht UND
  # fuer die Pflichtdokumente. Ohne Saison an der Hauptliga bleibt nur sie selbst,
  # damit der fehlende Anker nicht ihre eigene Zustaendigkeit kippt.
  test 'season_leagues enthaelt nur Ligen der Saison der Hauptliga' do
    haupt = create(:league, :current_season)
    gleiche = create(:league, :current_season)
    fremde = create(:league, :previous_season)
    team = create(:team, league: haupt)
    team.update!(cup_leagues: [gleiche.id, fremde.id])

    assert_equal [haupt.id, gleiche.id].sort, team.season_leagues.map(&:id).sort
  end

  test 'season_leagues ist leer ohne Hauptliga und nur sie selbst ohne Saison' do
    haupt = create(:league, :current_season)
    team = create(:team, league: haupt)

    haupt.update_columns(season_id: nil)
    assert_equal [haupt.id], team.reload.season_leagues.map(&:id)

    team.update_columns(league_id: nil)
    assert_empty team.reload.season_leagues
  end
end
