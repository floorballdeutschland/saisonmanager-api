# frozen_string_literal: true

# Öffentliche Abgabe des Schiri-Feedbacks über einen Einmal-Link, ohne Anmeldung.
# Gedacht für Kapitän*innen und andere von der Mannschaft benannte Personen, die
# bewusst kein Benutzerkonto bekommen (siehe RefereeFeedbackContact).
#
# Der Token ist die einzige Berechtigung und gilt nur für genau ein Spiel und
# genau eine Mannschaft. Deshalb gibt die Antwort ausschließlich die Kopfdaten
# dieser einen Begegnung heraus, keine weiteren Daten des Systems. Gegen das
# Durchprobieren von Tokens greift ein IP-Throttle (config/initializers/
# rack_attack.rb).
class RefereeFeedbackInvitationsController < ApplicationController
  skip_before_action :authenticate_user

  INVALID_MESSAGE = 'Dieser Link ist ungültig.'

  # GET /api/v2/referee_feedback_invitations/:token
  def show
    invitation = RefereeFeedbackInvitation.find_by_token(params[:token])
    return render json: { message: INVALID_MESSAGE }, status: :gone if invitation.nil?

    render json: invitation_json(invitation)
  end

  # POST /api/v2/referee_feedback_invitations/:token
  def create
    invitation = RefereeFeedbackInvitation.find_by_token(params[:token])
    return render json: { message: INVALID_MESSAGE }, status: :gone if invitation.nil?

    error = blocking_error(invitation)
    return render json: { error: error }, status: :unprocessable_entity if error

    feedback, submit_error = submit(invitation)
    return render json: { error: submit_error }, status: :unprocessable_entity if submit_error

    invitation.update_columns(used_at: Time.current) unless invitation.used?
    render json: status_payload(feedback),
           status: feedback.previously_new_record? ? :created : :ok
  end

  private

  def submit(invitation)
    RefereeFeedbackSubmission.new(
      game: invitation.game,
      team: invitation.team,
      attributes: params,
      submitted_by_player_id: invitation.player_id,
      submitted_by_email: invitation.email
    ).call
  end

  # Gründe, aus denen der Link nicht (mehr) zur Abgabe berechtigt.
  def blocking_error(invitation)
    return 'Dieser Link ist abgelaufen.' if invitation.expired?
    return 'Über diesen Link wurde bereits ein Feedback abgegeben.' if invitation.used?
    return 'Für dieses Spiel wurde bereits ein Feedback abgegeben.' if feedback_exists?(invitation)
    return 'Für diese Liga ist kein Schiri-Feedback vorgesehen.' unless feedback_enabled?(invitation)

    nil
  end

  def feedback_exists?(invitation)
    RefereeFeedback.exists?(game_id: invitation.game_id, team_id: invitation.team_id)
  end

  def feedback_enabled?(invitation)
    invitation.game.league&.referee_feedback_enabled?
  end

  # Kopfdaten der einen Begegnung plus Zustand des Links. Bewusst ohne die
  # Inhalte eines bereits abgegebenen Feedbacks: Auch der abgebenden Seite werden
  # Bewertungen und Kommentare nicht zurückgespielt.
  def invitation_json(invitation)
    game = invitation.game
    team = invitation.team
    opponent = team.id == game.home_team_id ? game.guest_team : game.home_team

    {
      status: link_status(invitation),
      team_name: team.name,
      opponent_name: opponent&.name,
      home: team.id == game.home_team_id,
      game_number: game.game_number,
      league: game.league&.name,
      date: game.game_day&.date,
      start_time: game.start_time,
      referees: game.feedback_referees.last,
      expires_at: invitation.expires_at&.iso8601
    }
  end

  def link_status(invitation)
    return 'expired' if invitation.expired?
    return 'submitted' if invitation.used? || feedback_exists?(invitation)
    return 'disabled' unless feedback_enabled?(invitation)

    'open'
  end

  # Bewusst ohne Bewertungen/Kommentare, analog UserRefereeFeedbacksController.
  def status_payload(feedback)
    {
      game_id: feedback.game_id,
      team_id: feedback.team_id,
      done: true,
      submitted_at: feedback.created_at.iso8601
    }
  end
end
