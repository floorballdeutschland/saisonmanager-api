class AddValidFromToGameDayLinks < ActiveRecord::Migration[7.2]
  def change
    add_column :game_day_secretary_links, :valid_from, :datetime,
               comment: 'Beginn des Gueltigkeitsfensters (72 h vor dem Spieltag). NULL = gilt ab Ausgabe (Altbestand).'
    add_column :game_day_overlay_links, :valid_from, :datetime,
               comment: 'Beginn des Gueltigkeitsfensters (72 h vor dem Spieltag). NULL = gilt ab Ausgabe (Altbestand).'
  end
end
