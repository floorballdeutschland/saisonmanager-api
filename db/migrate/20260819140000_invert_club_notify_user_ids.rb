# Aus der Auswahlliste wird eine Abwahlliste: Vereinsmanager bekommen die
# Vereinspost ab sofort standardmäßig, wer sie nicht will, wird abgewählt.
#
# Eine Auswahlliste kann das nicht leisten: Eine leere Liste hieße dort
# entweder „noch nie eingestellt" oder „bewusst niemand" – nicht zu
# unterscheiden. Ein neu berufener Vereinsmanager wäre in beiden Fällen
# draußen und hätte die Post erst bekommen, nachdem ihn jemand von Hand
# angehakt hätte. Genau das soll nicht mehr nötig sein.
#
# Die Bestandsdaten werden dabei bewusst zurückgesetzt (leere Abwahl = alle
# angehakt), so ausdrücklich gewünscht. Das Feature ist fünf Tage alt, die
# Auswahl war entsprechend dünn gepflegt.
class InvertClubNotifyUserIds < ActiveRecord::Migration[7.1]
  def up
    rename_column :clubs, :notify_user_ids, :notify_excluded_user_ids
    execute "UPDATE clubs SET notify_excluded_user_ids = '{}'"
  end

  # Nicht umkehrbar: Die alte Auswahl ist mit dem Zurücksetzen weg. Ein
  # zurückgedrehtes Feld hieße wieder „niemand bekommt Post", und das wäre
  # eine stille Fehlinformation, kein Rückbau.
  def down
    rename_column :clubs, :notify_excluded_user_ids, :notify_user_ids
    execute "UPDATE clubs SET notify_user_ids = '{}'"
  end
end
