class Club < ApplicationRecord
  has_many :game_days

  def home_game_operation
    Rails.cache.fetch("#{cache_key}/home_game_operation", expires_in: 1.week) do
      go = game_operations_hash.select { |g| g['home_game_operation'] == true }
      GameOperation.find_by_id go.first['game_operation_id']
    end
  end

  def update_state
    return if postcode.blank?

    states = Club.postcodes.select { |pc| pc[:from] < postcode.to_i && pc[:till] > postcode.to_i }

    if states.present?
      state = states.first[:isocode]
      update_attributes(state:)
    end
  end

  def full_hash
    {
      id:,
      long_name:,
      name:,
      state:,
      logo_url:,
      logo_small_url:
    }
  end
end
