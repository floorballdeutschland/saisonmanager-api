class Transfer < ApplicationRecord
  self.primary_key = :id

  belongs_to :player, optional: true
  belongs_to :former_club, class_name: 'Club', foreign_key: 'former_club_id', optional: true
  belongs_to :new_club, class_name: 'Club', foreign_key: 'new_club_id', optional: true

  # Einziger Aufrufer ist der oeffentliche Endpunkt `transfers/public`, deshalb
  # wird hier maskiert und nicht erst dort: Die Vereinswechsel der laufenden
  # Saison stehen ohne Anmeldung im Netz, und wer mitten in der Saison aufhoert
  # und die Loeschung seiner oeffentlichen Daten beantragt, steht sonst weiterhin
  # mit vollem Namen darin (PublicPlayerNames). Die Antwort liegt zusaetzlich
  # 30 Minuten im gemeinsamen Cache; den Schluessel raeumt `flush_for!` mit ab.
  def as_json(options = {})
    first_name, last_name = PublicPlayerNames.mask_names(player&.id, player&.first_name, player&.last_name)

    {
      id: id,
      transfer_date: created_at,
      # Die Bedingung bleibt am UNMASKIERTEN Bestand haengen, damit der Endpunkt
      # genau dieselben Faelle auf nil laufen laesst wie vorher: Ein Profil ohne
      # Vor- oder Nachnamen ergibt weiter nil, ein maskiertes den Platzhalter.
      player_name: player&.first_name.present? && player&.last_name.present? ? [first_name, last_name].compact_blank.join(' ') : nil,
      player_first_name: first_name,
      player_last_name: last_name,
      former_club_name: former_club&.name,
      new_club_name: new_club&.name
    }
  end
end
