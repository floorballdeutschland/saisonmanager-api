module Admin
  # SBK-Sicht auf Verfahrensvorschläge: offene Fälle prüfen und entweder ablehnen
  # (Dokumente verwerfen) oder ein Verfahren eröffnen (VSK-Mail im Namen der SBK).
  class ProceedingProposalsController < ApplicationController
    before_action :authorize_sbk_access!
    before_action :set_proposal, only: %i[show reject open]
    before_action :authorize_proposal_scope!, only: %i[show reject open]

    # GET /api/v2/admin/proceeding_proposals
    def index
      scope = ProceedingProposal.pending.includes(game: { game_day: :league })
      scope = scope.references(:leagues).where(leagues: { game_operation_id: allowed_go_ids }) unless full_access?
      render json: scope.map { |proposal| short_hash(proposal) }
    end

    # GET /api/v2/admin/proceeding_proposals/:id
    def show
      render json: full_hash(@proposal)
    end

    # POST /api/v2/admin/proceeding_proposals/:id/reject
    # Verwirft die Unterlagen und schließt den Vorschlag ab (irreversibel).
    def reject
      report = @proposal.report
      report&.file&.purge
      report&.destroy
      @proposal.update!(status: 'rejected', decided_by_id: current_user.id, decided_at: Time.current)
      render json: full_hash(@proposal)
    end

    # POST /api/v2/admin/proceeding_proposals/:id/open
    # Eröffnet das Verfahren: VSK-Mail (Reply-To = SBK) und Status opened.
    def open
      send_report_to_vsk(@proposal)
      @proposal.update!(status: 'opened', decided_by_id: current_user.id, decided_at: Time.current)
      render json: full_hash(@proposal)
    end

    private

    def set_proposal
      @proposal = ProceedingProposal.find_by(id: params[:id])
      render json: { error: 'Verfahrensvorschlag nicht gefunden' }, status: :not_found if @proposal.nil?
    end

    def authorize_sbk_access!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def authorize_proposal_scope!
      return if full_access? || allowed_go_ids.include?(@proposal.game_operation_id)

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def full_access?
      ph = current_user.permission_hash
      ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0))
    end

    def allowed_go_ids
      current_user.permission_hash[:sbk] || []
    end

    def send_report_to_vsk(proposal)
      game = proposal.game
      vsk_email = proposal.state_association.vsk_email
      report = proposal.report
      return if vsk_email.blank? || report.nil?

      assignment = game.referee_assignment
      RefereeMailer.referee_report_to_vsk(
        vsk_email, User.find_by(id: proposal.created_by_id), game, report,
        assignment&.referee1, assignment&.referee2,
        game_url: "#{FrontendUrl.base}/spielbericht/#{game.id}",
        checklist_answers: game.checklist_answers || []
      ).deliver_later
    end

    def short_hash(proposal)
      game = proposal.game
      {
        id: proposal.id,
        status: proposal.status,
        created_at: proposal.created_at,
        game_id: game.id,
        game_number: game.game_number,
        game_date: game.game_day.date,
        home_team: game.home_team_name,
        guest_team: game.guest_team_name,
        league_name: game.league.name,
        state_association_id: proposal.state_association_id
      }
    end

    def full_hash(proposal)
      report = proposal.report
      attached = report&.file&.attached?
      short_hash(proposal).merge(
        decided_at: proposal.decided_at,
        report: attached ? { filename: report.file.filename.to_s, url: rails_blob_url(report.file, disposition: 'inline') } : nil
      )
    end
  end
end
