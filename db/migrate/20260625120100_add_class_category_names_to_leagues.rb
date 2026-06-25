# Eingefrorene Anzeige-Namen der Liga-Klasse/-Kategorie. Werden beim Anlegen
# aus Setting übernommen, damit eine spätere Umbenennung in Setting alte Ligen
# nicht rückwirkend verändert. Nullable: Bestandsligen werden per Backfill-Task
# (rake leagues:freeze_labels) nachgezogen.
class AddClassCategoryNamesToLeagues < ActiveRecord::Migration[7.1]
  def change
    add_column :leagues, :league_class_name, :string
    add_column :leagues, :league_category_name, :string
  end
end
