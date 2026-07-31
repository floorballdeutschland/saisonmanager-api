# Die beiden Textspalten stammen aus dem Ur-Schema und waren die letzte
# Logo-Quelle neben dem Upload am Landesverband. Es gab keine Oberfläche, um sie
# zu pflegen, ein Teil der Werte zeigte auf fremde Server (Hotlinks), und
# `logo_quad_url` wurde vom Frontend nie gerendert.
#
# Rückwärts läuft die Migration strukturell sauber, die Inhalte kommen dabei aber
# nicht zurück. Vor dem Ausführen auf Produktion muss jeder Spielbetrieb, der
# heute noch aus diesen Spalten bedient wird, sein Logo im Uploadbereich der
# Verbandseinstellungen hinterlegt haben, sonst verschwindet es aus Seitenleiste
# und Startseite.
class RemoveLegacyLogoColumnsFromGameOperations < ActiveRecord::Migration[7.1]
  def up
    remove_column :game_operations, :logo_url
    remove_column :game_operations, :logo_quad_url
  end

  def down
    add_column :game_operations, :logo_url, :string
    add_column :game_operations, :logo_quad_url, :string
  end
end
