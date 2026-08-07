class CreateGameDaySecretaryLinkGameDays < ActiveRecord::Migration[7.1]
  # Ein Spielsekretariats-Link deckte bisher genau einen Spieltag ab. Spielen an
  # einem Tag in derselben Halle mehrere Ligen, sind das mehrere GameDay-Sätze
  # (arena_id sitzt am Spieltag, nicht am Spiel) und das Sekretariat am Tisch
  # brauchte pro Liga einen eigenen Link. Die Zuordnung wird deshalb n:m.
  #
  # Welche Spieltage ein Link abdeckt, wird beim Erzeugen festgeschrieben statt
  # bei jeder Anfrage aus Halle+Datum neu abgeleitet: nur so bleibt geprüft, dass
  # der Ersteller für jeden einzelnen Spieltag berechtigt war, und ein später
  # umgeplanter Spieltag wandert nicht nachträglich in einen laufenden Link.
  def up
    create_table :game_day_secretary_link_game_days do |t|
      t.references :game_day_secretary_link, null: false, foreign_key: true,
                                             index: { name: 'index_secretary_link_game_days_on_link_id' }
      t.references :game_day, null: false, foreign_key: true,
                              index: { name: 'index_secretary_link_game_days_on_game_day_id' }
      t.timestamps
    end

    add_index :game_day_secretary_link_game_days,
              %i[game_day_secretary_link_id game_day_id],
              unique: true,
              name: 'index_secretary_link_game_days_unique'

    execute <<~SQL.squish
      INSERT INTO game_day_secretary_link_game_days
        (game_day_secretary_link_id, game_day_id, created_at, updated_at)
      SELECT id, game_day_id, NOW(), NOW() FROM game_day_secretary_links
    SQL

    remove_column :game_day_secretary_links, :game_day_id
  end

  def down
    add_column :game_day_secretary_links, :game_day_id, :bigint
    add_index :game_day_secretary_links, :game_day_id

    # Rückwärts bleibt je Link der Spieltag mit der kleinsten ID erhalten, mehr
    # trägt die alte Spalte nicht. Links ohne Spieltag würden die NOT-NULL-Bedingung
    # verletzen und werden deshalb entfernt; sie leben ohnehin nur 72 Stunden.
    execute <<~SQL.squish
      UPDATE game_day_secretary_links l
         SET game_day_id = (
               SELECT game_day_id FROM game_day_secretary_link_game_days
                WHERE game_day_secretary_link_id = l.id
                ORDER BY game_day_id LIMIT 1)
    SQL
    execute 'DELETE FROM game_day_secretary_links WHERE game_day_id IS NULL'

    change_column_null :game_day_secretary_links, :game_day_id, false
    add_foreign_key :game_day_secretary_links, :game_days

    drop_table :game_day_secretary_link_game_days
  end
end
