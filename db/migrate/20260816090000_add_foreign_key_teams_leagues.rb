# Schritt 4 aus #293: `teams.league_id` bekommt den Fremdschlüssel, den
# `game_days` und `league_qualifications` längst haben.
#
# Ohne ihn kann eine Mannschaft auf eine Liga zeigen, die es nicht mehr gibt, und
# niemand merkt es. Woher der Altbestand stammt, ist nicht mehr rekonstruierbar;
# belegbar ist nur `League...delete_all` aus der Konsole. Der Weg über die
# Anwendung ist sauber, `LeaguesController#admin_league_delete` nimmt die
# Mannschaften in derselben Transaktion mit.
#
# Was sich ändert: Auf allen Wegen AUSSER `admin_league_delete` schlägt das
# Löschen einer Liga mit Mannschaften künftig als
# `ActiveRecord::InvalidForeignKey` fehl. Der Controller selbst räumt die
# Mannschaften vorher ab und trifft den Fremdschlüssel nie; sein bestehender
# Rescue (seit #269) fängt weiterhin die übrigen Verknüpfungen ab und antwortet
# mit 422.
#
# Der Fremdschlüssel greift außerdem auf UPDATE und INSERT, nicht nur auf das
# Löschen: Ein Import, der eine `league_id` aus einer Fremd-Datenbank schreibt,
# scheitert ab jetzt hart, statt still eine Waise anzulegen. Das ist der Zweck.
#
# `cup_leagues` bleibt ungeschützt, dort ist kein Fremdschlüssel möglich
# (Integer-Array). Die Quelle der dortigen Fälle ist stattdessen im selben
# Änderungssatz geschlossen worden, siehe `cleanup_stale_games.rake`.
#
# `league_id` bleibt nullable: Der Fremdschlüssel greift bei NULL nicht, und es
# gibt Mannschaften ohne Liga. Die melden sich seit #283 mit einer eigenen,
# verständlichen Meldung. Ob daraus ein NOT NULL werden soll, ist eine fachliche
# Frage und keine Migration: `Team belongs_to :league` erzwingt die Liga für
# jeden Speicherweg der Anwendung ohnehin schon.
#
# Bewusst kein Index auf `teams.league_id`: Postgres legt zur referenzierenden
# Spalte keinen an, jede Liga-Löschung prüft die Kindtabelle also per Seq Scan.
# Bei rund 10.000 Mannschaften und einer Handvoll Löschungen pro Saison ist das
# nicht messbar; ein Index kostet dagegen bei jedem Schreibvorgang.
class AddForeignKeyTeamsLeagues < ActiveRecord::Migration[7.1]
  def up
    return if foreign_key_exists?(:teams, :leagues)

    # Vorabprüfung nur für die klare Meldung: `add_foreign_key` scheitert sonst
    # mit einem Postgres-Fehler, aus dem nicht hervorgeht, was zu tun ist.
    # Migrationen laufen beim Deploy automatisch, die Meldung liest also jemand
    # unter Zeitdruck. Vor dem Deploy auf Produktion und Staging als leer
    # gemessen; diese Prüfung ermittelt es beim Lauf erneut.
    #
    # `connection.select_value` statt `select_value`: Letzteres liefe über
    # `Migration#method_missing`, das das erste Argument durch
    # `proper_table_name` schiebt und das ganze SQL als Schrittnamen ins
    # Deploy-Log schreibt.
    orphans = connection.select_value(<<~SQL.squish).to_i
      SELECT count(*)
      FROM teams t
      LEFT JOIN leagues l ON l.id = t.league_id
      WHERE t.league_id IS NOT NULL AND l.id IS NULL
    SQL

    if orphans.positive?
      # ONLY=league_id, weil nur diese Hälfte die Migration blockiert. Ohne die
      # Eingrenzung schriebe der Lauf ungefragt auch die Pokalliga-Angaben um,
      # von denen in dieser Meldung kein Wort steht. Der Dry-Run steht zuerst:
      # Die Ausgabe ist die einzige Aufzeichnung der verwaisten IDs, `update_all`
      # fasst `updated_at` nicht an.
      raise ActiveRecord::MigrationError,
            "#{orphans} Mannschaft(en) zeigen auf eine gelöschte Liga (#293). " \
            'Erst `ONLY=league_id rake cleanup:orphan_team_leagues` zur Vorschau, ' \
            'dann `DRY_RUN=false ONLY=league_id rake cleanup:orphan_team_leagues | tee /tmp/orphan.log`.'
    end

    add_foreign_key :teams, :leagues
  end

  def down
    remove_foreign_key :teams, :leagues
  end
end
