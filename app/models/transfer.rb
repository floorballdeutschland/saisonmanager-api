class Transfer < ApplicationRecord
  self.primary_key = :id

  belongs_to :player, optional: true
  belongs_to :former_club, class_name: 'Club', foreign_key: 'former_club_id', optional: true
  belongs_to :new_club, class_name: 'Club', foreign_key: 'new_club_id', optional: true

  def as_json(options = {})
    {
      id: id,
      transfer_date: created_at,
      player_name: player&.first_name && player&.last_name ? "#{player.first_name} #{player.last_name}" : nil,
      player_first_name: player&.first_name,
      player_last_name: player&.last_name,
      former_club_name: former_club&.name,
      new_club_name: new_club&.name
    }
  end
end
