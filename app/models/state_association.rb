class StateAssociation < ApplicationRecord
  has_many :checklist_items, class_name: 'StateAssociationChecklistItem', dependent: :destroy

  validates :name, presence: true

  def short_hash
    { id:, name:, short_name: }
  end

  def full_hash
    {
      id:,
      name:,
      short_name:,
      scan_required:,
      vsk_email:,
      sbk_email:,
      checklist_items: checklist_items.map { |i| { id: i.id, question: i.question, position: i.position } }
    }
  end
end
