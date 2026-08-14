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
end
