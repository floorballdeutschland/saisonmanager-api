class PlayerChangeRequest < ApplicationRecord
  CORRECTION_TYPES = %w[birthdate first_name last_name names_swapped nationality gender merge].freeze
  STATUSES = %w[pending approved rejected].freeze

  belongs_to :player
  belongs_to :club
  # Nur bei correction_type 'merge': das Duplikat, das in `player` (Master)
  # aufgehen soll.
  belongs_to :secondary_player, class_name: 'Player', optional: true

  validates :correction_type, inclusion: { in: CORRECTION_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :new_value, presence: true, unless: -> { %w[names_swapped merge].include?(correction_type) }
  validates :new_value, inclusion: { in: %w[M W D] }, if: -> { correction_type == 'gender' }
  validate :new_value_must_be_a_date, if: -> { correction_type == 'birthdate' && new_value.present? }
  validates :rejection_reason, presence: true, if: -> { status == 'rejected' }
  validates :secondary_player, presence: true, if: -> { correction_type == 'merge' }
  # Nur beim Anlegen: nach dem Genehmigen ist der secondary_player gemergt und
  # würde diese Prüfungen naturgemäß nicht mehr bestehen.
  validate :merge_must_be_executable, on: :create,
                                      if: -> { correction_type == 'merge' && secondary_player.present? }

  scope :pending, -> { where(status: 'pending') }
  scope :for_club, ->(club_id) { where(club_id: club_id) }
  scope :for_go, lambda { |go_ids|
    club_ids = go_ids.include?(0) ? Club.pluck(:id) : Club.all.select { |c| go_ids.include?(c.main_game_operation_id) }.map(&:id)
    where(club_id: club_ids)
  }

  def apply!(reviewed_by_user_id)
    case correction_type
    when 'birthdate'
      # birthdate ist eine date-Spalte: ein unlesbarer String würde beim
      # Zuweisen still zu nil gecastet und das Geburtsdatum löschen –
      # deshalb explizit parsen und bei Unlesbarkeit laut scheitern.
      player.update!(birthdate: parsed_birthdate!)
    when 'first_name'
      player.update!(first_name: new_value)
    when 'last_name'
      player.update!(last_name: new_value)
    when 'names_swapped'
      player.update!(first_name: player.last_name, last_name: player.first_name)
    when 'nationality'
      player.update!(nation_id: new_value.to_i)
    when 'gender'
      player.update!(gender: new_value)
    when 'merge'
      merge_players!(reviewed_by_user_id)
    end

    update!(status: 'approved', reviewed_by_user_id: reviewed_by_user_id)
  end

  def as_json(*)
    {
      id:,
      correction_type:,
      new_value:,
      status:,
      rejection_reason:,
      created_at: created_at&.iso8601,
      player: {
        id: player.id,
        first_name: player.first_name,
        last_name: player.last_name,
        birthdate: player.birthdate,
        nation_id: player.nation_id
      },
      club: { id: club.id, name: club.name },
      secondary_player: secondary_player_json,
      requested_by_user_id:,
      reviewed_by_user_id:
    }
  end

  private

  def secondary_player_json
    return nil unless secondary_player

    {
      id: secondary_player.id,
      first_name: secondary_player.first_name,
      last_name: secondary_player.last_name,
      birthdate: secondary_player.birthdate,
      deactivated_at: secondary_player.deactivated_at&.iso8601
    }
  end

  # Player#merge_into! prüft selbst nochmal (identische IDs, bereits gemergt,
  # gemeinsames Spiel) – der Zustand kann sich seit Antragstellung geändert
  # haben. ArgumentError in RecordInvalid übersetzen, damit der Controller ein
  # 422 mit Begründung liefert statt eines 500ers.
  def merge_players!(reviewed_by_user_id)
    secondary_player.merge_into!(player, reviewed_by_user_id)
  rescue ArgumentError => e
    errors.add(:base, e.message)
    raise ActiveRecord::RecordInvalid, self
  end

  def merge_must_be_executable
    if secondary_player_id == player_id
      errors.add(:secondary_player, 'darf nicht der gleiche Spieler sein')
      return
    end

    errors.add(:secondary_player, 'ist bereits zusammengeführt') if secondary_player.merged_into_id.present?
    errors.add(:player, 'ist bereits zusammengeführt') if player.merged_into_id.present?
    return unless errors.empty? && secondary_player.shares_game_with?(player)

    errors.add(:base, 'Beide Spieler kommen im selben Spiel vor und können kein Duplikat sein')
  end

  def parsed_birthdate!
    Date.parse(new_value.to_s)
  rescue ArgumentError, TypeError
    errors.add(:new_value, 'muss ein gültiges Datum sein (JJJJ-MM-TT)')
    raise ActiveRecord::RecordInvalid, self
  end

  def new_value_must_be_a_date
    Date.parse(new_value.to_s)
  rescue ArgumentError, TypeError
    errors.add(:new_value, 'muss ein gültiges Datum sein (JJJJ-MM-TT)')
  end
end
