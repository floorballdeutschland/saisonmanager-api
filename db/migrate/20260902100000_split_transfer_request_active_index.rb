class SplitTransferRequestActiveIndex < ActiveRecord::Migration[7.0]
  ACTIVE = "status IN ('pending_club', 'pending_player', 'pending_lv', 'scheduled')".freeze

  # Bis hierher galt: hoechstens EIN laufender Antrag je Spieler, egal welcher
  # Art. Fuer Transfers ist das die Fachregel (ein Spieler wechselt nicht in
  # zwei Vereine), fuer Freigaben war es eine Nebenwirkung -- eine laufende
  # Freigabe sperrte die naechste, obwohl ein Spieler durchaus fuer mehrere
  # Vereine eine Freigabe braucht.
  #
  # Neu deshalb zwei Riegel statt einem:
  #   * je Spieler hoechstens ein laufender TRANSFER (unveraendert streng),
  #   * je Spieler und Zielverein hoechstens eine laufende FREIGABE.
  #
  # Der zweite verhindert nur das Duplikat auf denselben Verein: Es waere
  # wirkungslos, weil add_secondary_club_membership! die bestehende
  # Mitgliedschaft erkennt und der zweite Antrag folgenlos auf "approved" liefe.
  #
  # request_type ist NOT NULL DEFAULT 'transfer', der Bestand fällt damit
  # vollstaendig in den Transfer-Riegel und kann ihn nicht verletzen -- er war
  # ja bisher der strengere.
  def up
    remove_index :transfer_requests, name: 'index_transfer_requests_on_player_id_active'

    add_index :transfer_requests, :player_id,
              unique: true,
              where: "#{ACTIVE} AND request_type = 'transfer'",
              name: 'index_transfer_requests_on_player_id_active_transfer'

    add_index :transfer_requests, %i[player_id requesting_club_id],
              unique: true,
              where: "#{ACTIVE} AND request_type = 'release'",
              name: 'index_transfer_requests_on_player_id_active_release'
  end

  # Die Ruecknahme scheitert, sobald ein Spieler zwei laufende Antraege hat --
  # genau die Zustaende, die diese Migration erst moeglich macht. Das ist
  # gewollt: Ein stiller Rueckbau muesste Antraege verwerfen.
  def down
    remove_index :transfer_requests, name: 'index_transfer_requests_on_player_id_active_release'
    remove_index :transfer_requests, name: 'index_transfer_requests_on_player_id_active_transfer'

    add_index :transfer_requests, :player_id,
              unique: true,
              where: ACTIVE,
              name: 'index_transfer_requests_on_player_id_active'
  end
end
