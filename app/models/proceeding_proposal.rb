# Verfahrensvorschlag: legt der SBK einen Spielberichtsfall (Berichtsformular-
# Upload) zur Entscheidung vor, statt automatisch die VSK zu benachrichtigen.
# Wird nur erzeugt, wenn der Landesverband sowohl `report_form_email_enabled`
# (Berichtsworkflow aktiv) als auch `manual_proceeding_creation` aktiviert hat,
# und nur bei einer vollen Matchstrafe (api#789). Ein abgelehnter Vorschlag wird
# bei einem neuen Upload wieder offen (siehe
# GameRefereeReportsController#_forward_manually).
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
