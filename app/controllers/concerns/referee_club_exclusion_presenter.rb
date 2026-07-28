# Gemeinsame Serialisierung der Vereins-Ausschlussliste für das Schiri-Portal
# und die Ansetzungs-Ansichten. Der eigene Verein ist ein abgeleiteter Eintrag
# (source "own_club") und steht nicht in referee_club_exclusions.
module RefereeClubExclusionPresenter
  extend ActiveSupport::Concern

  private

  # Schlanke Vereinsliste für die Auswahl im Antrag bzw. bei der direkten Pflege.
  # Bewusst alle aktiven Vereine: Ein Ausschluss kann jeden Verein betreffen,
  # nicht nur die des eigenen Landesverbands.
  #
  # Bewusst ungecacht: Ein frisch angelegter oder deaktivierter Verein müsste
  # sonst in ClubsController an drei Stellen invalidiert werden, und der
  # pluck über ein paar hundert Zeilen ist billiger als diese Kopplung.
  def active_clubs_json
    Club.active.order(:name).pluck(:id, :name).map { |id, name| { id:, name: } }
  end

  def club_exclusions_json(referee)
    entries = []

    if referee.club.present?
      entries << {
        id: nil,
        club_id: referee.club_id,
        club_name: referee.club.name,
        source: 'own_club',
        reason: nil,
        since: nil,
        can_request_removal: false
      }
    end

    referee.referee_club_exclusions.includes(:club).each do |exclusion|
      entries << {
        id: exclusion.id,
        club_id: exclusion.club_id,
        club_name: exclusion.club&.name,
        source: 'assigned',
        reason: exclusion.reason,
        since: exclusion.created_at&.iso8601,
        can_request_removal: true
      }
    end

    entries.sort_by { |entry| entry[:club_name].to_s.downcase }
  end

  def club_exclusion_requests_json(referee)
    referee.referee_club_exclusion_requests
           .includes(:club)
           .order(created_at: :desc)
           .map(&:as_json)
  end
end
