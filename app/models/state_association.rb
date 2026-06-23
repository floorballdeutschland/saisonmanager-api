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

  # Abweichende Semantik zu effective_express_license_enabled (oben): Parent-LV
  # dominiert; das eigene Flag wird ignoriert, sobald ein Parent gesetzt ist.
  # Hintergrund: Der Schiedsrichter-Kursergebnis-Import wird vom uebergeordneten
  # LV kontrolliert. StateAssociationsController erzwingt zusaetzlich
  # referee_license_review_enabled = false fuer Kinder-LVs, damit dieses Feld
  # nicht aus Versehen lokal gesetzt wird. Tests in
  # referee_course_submit_policy_test.rb verankern diese Semantik.
  def effective_referee_license_review_enabled
    return parent.referee_license_review_enabled if parent

    referee_license_review_enabled
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

  # season_id (optional): Blickt in die Freigaben einer vergangenen Saison
  # zurück. Ohne Param bleibt der Default die aktuelle Saison – damit eine
  # künftige Saisonenauswahl in der UI auch historische Audit-Einträge zeigen
  # kann (siehe Issue #191).
  def full_hash(season_id: nil)
    release_scope = season_id.present? ? releases.where(season_id:) : releases.current_season
    {
      id:,
      name:,
      short_name:,
      scan_required:,
      vsk_email:,
      sbk_email:,
      parent_id:,
      parent_name: parent&.name,
      express_license_enabled:,
      referee_license_review_enabled:,
      effective_referee_license_review_enabled:,
      manual_proceeding_creation:,
      referee_assignment_enabled:,
      logo_url:,
      banner_url:,
      banner_link_url:,
      children: children.order(:name).map(&:short_hash),
      checklist_items: checklist_items.map { |i| { id: i.id, question: i.question, position: i.position } },
      releases: release_scope.includes(:recipient_game_operation).map do |r|
        {
          id: r.id,
          recipient_game_operation_id: r.recipient_game_operation_id,
          recipient_game_operation_name: r.recipient_game_operation.name,
          season_id: r.season_id
        }
      end
    }
  end
end
