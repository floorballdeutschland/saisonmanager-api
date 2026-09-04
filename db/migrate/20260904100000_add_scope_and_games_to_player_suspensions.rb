# Geltungsbereich und Spielezaehler fuer Spielersperren (#604).
#
# Bisher kannte eine Sperre nur ein Datumsfenster und zwei Ebenen: den ganzen
# Spieler (team_id NULL) oder eine einzelne Team-Lizenz. Neu ist zum einen die
# Dauer in Spielen, zum anderen der waehlbare Wettbewerb.
class AddScopeAndGamesToPlayerSuspensions < ActiveRecord::Migration[7.2]
  def up
    # Der Geltungsbereich. 'team' und 'all' bilden die beiden bisherigen Ebenen
    # ab, 'competition' und 'league' sind neu.
    add_column :player_suspensions, :scope_kind, :string

    # Dauer in Spielen. NULL heisst: Datumssperre wie bisher.
    add_column :player_suspensions, :games_total, :integer
    add_column :player_suspensions, :games_served, :integer, default: 0, null: false
    # Die Spiele, die gezaehlt wurden. Ohne dieses Protokoll wuerde ein erneut
    # geoeffneter und wieder abgeschlossener Spielbericht doppelt zaehlen.
    add_column :player_suspensions, :served_game_ids, :jsonb, default: [], null: false

    # Aufgeloester Wettbewerbsschluessel. Als Kopie und nicht als Verweis auf
    # die Liga, damit eine Sperre nicht ihre Bedeutung aendert, wenn die Liga
    # nachtraeglich umgestellt wird.
    add_column :player_suspensions, :season_id, :string
    add_column :player_suspensions, :age_group, :string
    add_column :player_suspensions, :field_size, :string
    add_column :player_suspensions, :competition_groups, :string, array: true, default: [], null: false
    add_column :player_suspensions, :league_id, :bigint

    # Eine Sperre ueber X Spiele braucht kein Enddatum mehr.
    change_column_null :player_suspensions, :valid_until, true

    # Bestand am 04.09.2026: 3 Sperren, alle datumsbasiert, zwei auf eine
    # Team-Lizenz und eine spielerweit. Die Bedeutung bleibt damit unveraendert.
    execute <<~SQL.squish
      UPDATE player_suspensions
      SET scope_kind = CASE WHEN team_id IS NULL THEN 'all' ELSE 'team' END
      WHERE scope_kind IS NULL
    SQL
    change_column_null :player_suspensions, :scope_kind, false

    add_index :player_suspensions, %i[scope_kind lifted_at]
  end

  def down
    remove_index :player_suspensions, %i[scope_kind lifted_at]
    remove_column :player_suspensions, :scope_kind
    remove_column :player_suspensions, :games_total
    remove_column :player_suspensions, :games_served
    remove_column :player_suspensions, :served_game_ids
    remove_column :player_suspensions, :season_id
    remove_column :player_suspensions, :age_group
    remove_column :player_suspensions, :field_size
    remove_column :player_suspensions, :competition_groups
    remove_column :player_suspensions, :league_id
    # Zurueck geht das nur, wenn keine Sperre ohne Enddatum existiert.
    execute("DELETE FROM player_suspensions WHERE valid_until IS NULL")
    change_column_null :player_suspensions, :valid_until, false
  end
end
