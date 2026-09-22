class AddPublicLastNameHiddenToPlayers < ActiveRecord::Migration[7.2]
  def change
    add_column :players, :public_last_name_hidden_at, :datetime,
               comment: 'Gesetzt = Name wird in der oeffentlichen Ausgabe (Scorer, Aufstellung, ' \
                        'Statistik, Overlay) durch einen Platzhalter ersetzt. Der Datensatz selbst ' \
                        'behaelt den Namen, damit Dubletten- und Sperrpruefung weiter greifen.'
    add_column :players, :public_last_name_hidden_by, :bigint,
               comment: 'Konto, das die Anonymisierung gesetzt hat.'
    add_column :players, :public_last_name_hidden_reason, :string,
               comment: 'Interner Vermerk, etwa das Aktenzeichen des Loeschantrags.'

    add_index :players, :public_last_name_hidden_at, where: 'public_last_name_hidden_at IS NOT NULL',
                                               name: 'index_players_on_public_last_name_hidden_at'
  end
end
