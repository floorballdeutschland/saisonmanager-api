# Verfahrensvorschlag: legt der SBK einen Spielberichtsfall (Berichtsformular-
# Upload) zur Entscheidung vor, statt automatisch die VSK zu benachrichtigen.
# Wird nur erzeugt, wenn der Landesverband sowohl `report_form_email_enabled`
# (Berichtsworkflow aktiv) als auch `manual_proceeding_creation` aktiviert hat
# (siehe GameRefereeReportsController#_send_to_vsk).
class ProceedingProposal < ApplicationRecord
  STATUSES = %w[pending rejected opened].freeze

  belongs_to :game
  belongs_to :state_association

  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: 'pending') }

  # Spielbetrieb des Spiels — Basis für den SBK-Scope.
  def game_operation_id
    game.league.game_operation_id
  end

  def report
    game.game_referee_report
  end
end
