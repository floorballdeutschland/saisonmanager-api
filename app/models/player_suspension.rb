class PlayerSuspension < ApplicationRecord
  belongs_to :player

  validates :valid_from, :valid_until, presence: true
  validate :valid_until_after_valid_from

  # Beantragungssperre (Ebene 2): gilt für den gesamten Spieler, blockiert neue Lizenzanträge.
  # Lizenzaussetzung (Ebene 1): bezieht sich auf eine einzelne Team-Lizenz.
  scope :player_wide, -> { where(team_id: nil) }
  scope :active, -> { where(lifted_at: nil) }
  scope :covering, ->(date) { where('valid_from <= :d AND valid_until >= :d', d: date) }
  scope :due, ->(date) { active.where('valid_until < ?', date) }

  def player_wide?
    team_id.nil?
  end

  def active?
    lifted_at.nil?
  end

  private

  def valid_until_after_valid_from
    return if valid_from.blank? || valid_until.blank?

    errors.add(:valid_until, 'muss nach dem Beginn liegen') if valid_until < valid_from
  end
end
