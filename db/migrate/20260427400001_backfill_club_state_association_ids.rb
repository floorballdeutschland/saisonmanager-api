class BackfillClubStateAssociationIds < ActiveRecord::Migration[7.0]
  # Maps main_game_operation_id -> state_association_id for non-FD game operations
  GO_TO_SA = {
    2 => 2,   # Niedersachsen
    3 => 3,   # Berlin-Brandenburg
    4 => 4,   # Baden-Württemberg
    5 => 5,   # Schleswig-Holstein
    6 => 6,   # SBK Ost
    8 => 7,   # Hessen
    9 => 8,   # Bayern
    10 => 9,  # NRW
    11 => 10, # Rheinland-Pfalz/Saar
  }.freeze

  # Maps club.state ISO code -> state_association_id (used for FD/GO-1 clubs)
  STATE_TO_SA = {
    'de-bw' => 4,  # Baden-Württemberg
    'de-by' => 8,  # Bayern
    'de-be' => 3,  # Berlin-Brandenburg
    'de-bb' => 3,  # Berlin-Brandenburg
    'de-hb' => 2,  # Niedersachsen (Bremen)
    'de-hh' => 14, # Hamburg
    'de-he' => 7,  # Hessen
    'de-mv' => 6,  # SBK Ost (Mecklenburg-Vorpommern)
    'de-ni' => 2,  # Niedersachsen
    'de-nw' => 9,  # NRW
    'de-rp' => 10, # RLP/Saar
    'de-sl' => 10, # RLP/Saar (Saarland)
    'de-sn' => 13, # Sachsen
    'de-st' => 11, # Sachsen-Anhalt
    'de-sh' => 5,  # Schleswig-Holstein
    'de-th' => 12, # Thüringen
  }.freeze

  def up
    Club.where(state_association_id: nil).find_each do |club|
      go_id = club.main_game_operation_id

      sa_id = GO_TO_SA[go_id]
      sa_id ||= STATE_TO_SA[club.state] if club.state.present?

      club.update_column(:state_association_id, sa_id) if sa_id
    end
  end

  def down
    Club.update_all(state_association_id: nil)
  end
end
