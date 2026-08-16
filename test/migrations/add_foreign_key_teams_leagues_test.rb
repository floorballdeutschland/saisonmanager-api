require 'test_helper'
require Rails.root.join('db/migrate/20260816090000_add_foreign_key_teams_leagues')

# Migration zu #293: Fremdschlüssel auf `teams.league_id`.
#
# Ohne diese Tests liefe `up` im gesamten Testlauf kein einziges Mal: Die
# Test-Datenbank kommt aus `db/schema.rb` und bringt den Fremdschlüssel schon
# mit. Ausgerechnet die Zeilen, die beim Deploy unter Zeitdruck gelesen werden,
# wären damit unausgeführter Code.
class AddForeignKeyTeamsLeaguesTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @club = create(:club)
    @connection = ActiveRecord::Base.connection
  end

  def migration
    AddForeignKeyTeamsLeagues.new
  end

  def run_up
    ActiveRecord::Migration.suppress_messages { migration.up }
  end

  def fk?
    @connection.foreign_key_exists?(:teams, :leagues)
  end

  def drop_fk
    @connection.remove_foreign_key(:teams, :leagues) if fk?
  end

  # Der Ausgangszustand vor der Migration, samt einer Mannschaft, deren Liga
  # gelöscht wurde. Genau diesen Bestand soll die Vorabprüfung finden.
  def orphan_before_migration
    weg = create(:league)
    team = create(:team, league: weg, club: @club)
    drop_fk
    League.unscoped.where(id: weg.id).delete_all
    team
  end

  test 'up setzt den Fremdschluessel auf sauberem Bestand' do
    create(:team, league: create(:league), club: @club)
    drop_fk
    assert_not fk?

    run_up

    assert fk?
  end

  test 'up bricht bei Waisen mit einer Meldung ab, die den Weg nennt' do
    orphan_before_migration

    fehler = assert_raises(ActiveRecord::MigrationError) { run_up }

    assert_match(/1 Mannschaft\(en\)/, fehler.message)
    assert_match(/cleanup:orphan_team_leagues/, fehler.message)
    assert_match(/ONLY=league_id/, fehler.message,
                 'die Meldung muss auf die Haelfte eingrenzen, die die Migration blockiert')
    assert_match(/#293/, fehler.message)
  end

  # Der Abbruch darf keinen halben Zustand hinterlassen.
  test 'nach dem Abbruch ist der Fremdschluessel nicht gesetzt' do
    orphan_before_migration

    assert_raises(ActiveRecord::MigrationError) { run_up }

    assert_not fk?
  end

  # Migrationen laufen beim Deploy automatisch; ein zweiter Lauf auf einer
  # bereits migrierten Datenbank darf nicht scheitern.
  test 'up ist idempotent' do
    assert fk?

    run_up

    assert fk?
  end

  test 'down entfernt den Fremdschluessel wieder' do
    assert fk?

    ActiveRecord::Migration.suppress_messages { migration.down }

    assert_not fk?
  end
end
