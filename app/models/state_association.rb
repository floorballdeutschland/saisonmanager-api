class StateAssociation < ApplicationRecord
  belongs_to :parent, class_name: 'StateAssociation', optional: true
  has_many :children, class_name: 'StateAssociation', foreign_key: :parent_id, dependent: :nullify
  has_many :checklist_items, class_name: 'StateAssociationChecklistItem', dependent: :destroy
  has_many :releases, class_name: 'StateAssociationRelease', foreign_key: :grantor_state_association_id,
                      dependent: :destroy

  validates :name, presence: true

  def effective_express_license_enabled
    express_license_enabled || parent&.express_license_enabled
  end

  def short_hash
    { id:, name:, short_name:, parent_id: }
  end

  def full_hash
    {
      id:,
      name:,
      short_name:,
      scan_required:,
      vsk_email:,
      sbk_email:,
      parent_id:,
      express_license_enabled:,
      children: children.order(:name).map(&:short_hash),
      checklist_items: checklist_items.map { |i| { id: i.id, question: i.question, position: i.position } },
      releases: releases.includes(:recipient_game_operation).map do |r|
        {
          id: r.id,
          recipient_game_operation_id: r.recipient_game_operation_id,
          recipient_game_operation_name: r.recipient_game_operation.name
        }
      end
    }
  end
end
