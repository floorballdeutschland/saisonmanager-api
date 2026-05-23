class StateAssociation < ApplicationRecord
  belongs_to :parent, class_name: 'StateAssociation', optional: true
  has_many :children, class_name: 'StateAssociation', foreign_key: :parent_id, dependent: :nullify
  has_many :checklist_items, class_name: 'StateAssociationChecklistItem', dependent: :destroy
  has_many :releases, class_name: 'StateAssociationRelease', foreign_key: :grantor_state_association_id,
                      dependent: :destroy
  has_one_attached :logo
  has_one_attached :banner

  validates :name, presence: true

  def effective_express_license_enabled
    express_license_enabled || parent&.express_license_enabled
  end

  def logo_url
    Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true) if logo.attached?
  end

  def banner_url
    Rails.application.routes.url_helpers.rails_blob_path(banner, only_path: true) if banner.attached?
  end

  def short_hash
    { id:, name:, short_name:, parent_id:, logo_url:, banner_url:, banner_link_url: }
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
      logo_url:,
      banner_url:,
      banner_link_url:,
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
