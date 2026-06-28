# Punktekorrekturen pro Liga (vorher global in Setting.point_corrections,
# keyed by league_id). An der Liga sind sie self-contained pro Saison und
# unabhängig von späteren Setting-Änderungen. Shape wie bisher:
# { "<team_id>" => { "points" => <int>, ... } }.
class AddPointCorrectionsToLeagues < ActiveRecord::Migration[7.1]
  def change
    add_column :leagues, :point_corrections, :jsonb, default: {}, null: false,
                                                     comment: 'Punktekorrekturen je Team ({ team_id => { points: ... } }); ersetzt das globale Setting.point_corrections'
  end
end
