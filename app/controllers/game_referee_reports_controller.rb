class GameRefereeReportsController < ApplicationController
  before_action :authenticate_user
  before_action :set_game

  # GET /api/v2/games/:game_id/referee_report
  #
  # Nicht berechtigte Nutzer bekommen bewusst kein 403, sondern { uploaded: false }:
  # Die Spieldetailseite ruft diesen Endpoint für jeden eingeloggten Nutzer auf, und
  # ein 403 triggert im Frontend den globalen ErrorInterceptor (Popup + Redirect auf
  # "/"). Die Blob-URL selbst bleibt geschützt (nur Admin/SBK-im-Scope/angesetzte
  # Schiris sehen `uploaded: true` + `url`).
  def show
    report = @game.game_referee_report
    if report&.file&.attached? && (admin_or_sbk_for_game? || authorized_referee?)
      render json: {
        uploaded: true,
        filename: report.file.filename.to_s,
        content_type: report.file.content_type,
        uploaded_at: report.created_at,
        url: rails_blob_url(report.file, disposition: 'inline')
      }
    else
      render json: { uploaded: false }
    end
  end

  # POST /api/v2/games/:game_id/referee_report
  def create
    unless authorized_referee?
      return render json: { message: 'Nur angesetzte Schiedsrichter können einen Bericht hochladen.' }, status: :forbidden
    end

    report = @game.game_referee_report || @game.build_game_referee_report(uploaded_by: current_user)
    report.uploaded_by = current_user
    report.file.attach(params[:file])

    if report.save
      _send_to_vsk(report)
      render json: { success: true, filename: report.file.filename.to_s }, status: :created
    else
      render json: { errors: report.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def set_game
    @game = Game.find(params[:game_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Spiel nicht gefunden' }, status: :not_found
  end

  def admin_or_sbk_for_game?
    ph = current_user.permission_hash
    return true if ph[:admin].present?
    return false if ph[:sbk].blank?
    return true if ph[:sbk].include?(0)

    ph[:sbk].include?(@game.league.game_operation_id)
  end

  def authorized_referee?
    assignment = @game.referee_assignment
    return false unless assignment

    referee = current_user.referee
    return false unless referee

    [assignment.referee1_id, assignment.referee2_id].include?(referee.id)
  end

  def _send_to_vsk(report)
    state_association = @game.game_day.club&.state_association

    # Manueller Workflow: kein automatischer VSK-Versand, stattdessen ein
    # Verfahrensvorschlag an die SBK (idempotent bei erneutem Upload).
    if state_association&.manual_proceeding_creation?
      _create_proceeding_proposal(state_association)
      return
    end

    vsk_email = state_association&.vsk_email
    return if vsk_email.blank?

    assignment = @game.referee_assignment
    r1 = assignment&.referee1
    r2 = assignment&.referee2

    frontend_base = Rails.env.production? ? 'https://saisonmanager.org' : 'http://localhost:4200'
    game_url = "#{frontend_base}/spielbericht/#{@game.id}"
    checklist_answers = @game.checklist_answers || []

    RefereeMailer.referee_report_to_vsk(
      vsk_email, current_user, @game, report, r1, r2,
      game_url: game_url, checklist_answers: checklist_answers
    ).deliver_later
  end

  def _create_proceeding_proposal(state_association)
    ProceedingProposal.find_or_create_by(game_id: @game.id) do |proposal|
      proposal.state_association = state_association
      proposal.status = 'pending'
      proposal.created_by_id = current_user.id
    end
  end
end
