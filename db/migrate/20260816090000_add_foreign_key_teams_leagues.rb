# Schritt 4 aus #293: `teams.league_id` bekommt den Fremdschlüssel, den
# `game_days` und `league_qualifications` längst haben.
#
# Ohne ihn kann eine Mannschaft auf eine Liga zeigen, die es nicht mehr gibt,
# und niemand merkt es. Der Weg über die Anwendung ist sauber
# (`LeaguesController#admin_league_delete` nimmt die Mannschaften in derselben
# Transaktion mit), verwaiste Datensätze entstehen auf allen anderen Wegen:
# `League.where(id: ...).delete_all` aus Konsole oder Rake-Task und die Import-
# und Restore-Tasks in `lib/tasks/`.
#
# Danach schlägt jeder weitere Versuch, eine Liga mit Mannschaften zu löschen,
# als `ActiveRecord::InvalidForeignKey` fehl. `admin_league_delete` behandelt
# diese Ausnahme bereits und antwortet mit 422.
#
# `league_id` bleibt nullable: Der Fremdschlüssel greift bei NULL nicht, und auf
# Produktion stehen vier Mannschaften ohne Liga. Eine Mannschaft ohne Liga
# meldet sich seit #283 mit einer eigenen, verständlichen Meldung. Ob daraus ein
# NOT NULL werden soll, ist eine eigene, fachliche Frage.
#
# Gemessen am 16.08.2026 auf Produktion und auf dem Staging-Klon: 10.028
# Mannschaften, davon **null** mit verwaister `league_id`. Die Migration läuft
# also durch, ohne dass vorher etwas bereinigt werden muss.
class AddForeignKeyTeamsLeagues < ActiveRecord::Migration[7.1]
  def up
    # Vorabprüfung nur für die klare Meldung: `add_foreign_key` scheitert sonst
    # mit einem Postgres-Fehler, aus dem nicht hervorgeht, was zu tun ist.
    # Migrationen laufen beim Deploy automatisch, die Meldung liest also jemand
    # unter Zeitdruck.
    orphans = select_value(<<~SQL.squish).to_i
      SELECT count(*)
      FROM teams t
      LEFT JOIN leagues l ON l.id = t.league_id
      WHERE t.league_id IS NOT NULL AND l.id IS NULL
    SQL

    if orphans.positive?
      raise ActiveRecord::MigrationError,
            "#{orphans} Mannschaft(en) zeigen auf eine gelöschte Liga. " \
            'Erst `DRY_RUN=false rake cleanup:orphan_team_leagues` laufen lassen, ' \
            'Bestand mit `rake data_health:orphan_teams` prüfen (#293).'
    end

    add_foreign_key :teams, :leagues
  end

  def down
    remove_foreign_key :teams, :leagues
  end
end
