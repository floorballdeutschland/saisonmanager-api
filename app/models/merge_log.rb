class MergeLog < ApplicationRecord
  OBJECT_TYPES = %w[player arena referee].freeze

  validates :object_type, inclusion: { in: OBJECT_TYPES }

  # Zusammenlegungen der letzten Monate (Standard: 6), neueste zuerst.
  scope :recent, ->(since = 6.months.ago) { where('created_at >= ?', since).order(created_at: :desc) }

  # Protokolliert eine Zusammenlegung. master_* = verbleibendes Objekt,
  # merged_* = aufgelöstes (zusammengeführtes) Objekt.
  def self.record!(object_type:, master_id:, merged_id:, user_id: nil, master_label: nil, merged_label: nil)
    create!(
      object_type: object_type,
      master_id: master_id,
      merged_id: merged_id,
      master_label: master_label,
      merged_label: merged_label,
      performed_by_user_id: user_id
    )
  end
end
