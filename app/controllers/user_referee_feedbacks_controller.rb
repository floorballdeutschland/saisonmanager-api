# Team-seitiges Schiri-Feedback (TM/VM). Listet die feedback-pflichtigen,
# bereits gespielten Spiele der eigenen Mannschaften und nimmt je Spiel und Team
# genau eine Rückmeldung entgegen. Analog zu TeamGameDayConfirmationsController.
#
# Die abgebende Seite sieht bewusst nur den Status (offen / erledigt) – die
# Inhalte (Bewertungen, Kommentare) sind ausschließlich in der Schiriverwaltung
# am Schiri-Profil sichtbar.
#
# Denselben Weg ohne Anmeldung gibt es für Kapitän*innen und andere benannte
# Personen über einen Einmal-Link (RefereeFeedbackInvitationsController). Beide
# Wege teilen die Annahme-Logik (RefereeFeedbackSubmission), es bleibt bei einem
# Feedback je Spiel und Mannschaft: Wer zuerst absendet, gewinnt.
class UserRefereeFeedbacksController < ApplicationController
  include ManagedTeams

  before_action :authenticate_user

  # Wie weit zurück gespielte Spiele in der Übersicht erscheinen.
  LOOKBACK_DAYS = 120

  # GET /api/v2/user/referee_feedbacks
  def index
    return render json: [] if managed_team_ids.empty?

    games = eligible_games
    feedbacks = RefereeFeedback
                .where(game_id: games.map(&:id))
                .index_by { |f| [f.game_id, f.team_id] }
    invitations = RefereeFeedbackInvitation
                  .where(game_id: games.map(&:id))
                  .index_by { |i| [i.game_id, i.team_id] }

    payload = games.flat_map do |game|
      participating_managed_teams(game).map do |team|
        game_feedback_json(game, team, feedbacks[[game.id, team.id]],
                           invitations[[game.id, team.id]])
      end
    end

    render json: payload.sort_by { |e| e[:date].to_s }.reverse
  end

  # POST /api/v2/user/referee_feedbacks
  def create
    game = Game.find(params[:game_id])
    team = Team.find(params[:team_id])

    unless eligible?(game) && participating_managed_team?(game, team)
      return render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    feedback, error = RefereeFeedbackSubmission.new(
      game: game,
      team: team,
      attributes: params,
      submitted_by_user_id: current_user.id
    ).call

    return render json: { error: error }, status: :unprocessable_entity if error

    render json: status_payload(feedback),
           status: feedback.previously_new_record? ? :created : :ok
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private

  # Spiele mit abgeschlossenem Spielbericht in feedback-pflichtigen Ligen, an
  # denen eine eigene Mannschaft beteiligt ist (Lookback-Fenster). Erst mit dem
  # Bericht-Abschluss öffnet das Feedback-Fenster, daher werden offene Berichte
  # noch nicht gelistet.
  def eligible_games
    Game
      .joins(game_day: :league)
      .includes(:home_team, :guest_team, game_day: :league)
      .where(leagues: { referee_feedback_enabled: true })
      .where(game_status: %w[match_record_closed finalized])
      .where('games.home_team_id IN (:t) OR games.guest_team_id IN (:t)', t: managed_team_ids)
      .where("TO_DATE(game_days.date, 'YYYY-MM-DD') BETWEEN ? AND ?",
             LOOKBACK_DAYS.days.ago.to_date, Date.current)
      .to_a
  end

  def eligible?(game)
    game.league&.referee_feedback_enabled? &&
      Date.parse(game.game_day.date) <= Date.current
  rescue ArgumentError, TypeError
    false
  end

  # Eigene Mannschaften, die an diesem Spiel beteiligt sind (i. d. R. genau eine).
  def participating_managed_teams(game)
    [game.home_team, game.guest_team].compact.select { |t| managed_team_ids.include?(t.id) }
  end

  def participating_managed_team?(game, team)
    return false if team.nil?
    return false unless managed_team_ids.include?(team.id)

    game.home_team_id == team.id || game.guest_team_id == team.id
  end

  # Ab wann das Formular ausfüllbar ist: mit dem Abschluss des Spielberichts
  # (match_record_closed_at). nil, solange der Bericht offen ist – dann ist noch
  # kein Feedback möglich.
  def fillable_from(game)
    game.match_record_closed? ? game.match_record_closed_at : nil
  end

  # invited_email macht sichtbar, an wen die Einladung zur Abgabe gegangen ist
  # (Kapitän*in oder hinterlegter Feedback-Kontakt). Wichtig, weil die Abgabe
  # Pflicht der Mannschaft bleibt: Der Teammanager soll erkennen, ob er selbst
  # nachfassen muss.
  def game_feedback_json(game, team, feedback, invitation = nil)
    opponent = team.id == game.home_team_id ? game.guest_team : game.home_team
    {
      game_id: game.id,
      team_id: team.id,
      team_name: team.name,
      opponent_name: opponent&.name,
      home: team.id == game.home_team_id,
      game_number: game.game_number,
      league: game.league&.name,
      date: game.game_day.date,
      start_time: game.start_time,
      referees: game.feedback_referees.last,
      fillable_from: fillable_from(game)&.iso8601,
      done: feedback.present?,
      submitted_at: feedback&.created_at&.iso8601,
      invited_email: invitation&.email,
      invited_at: invitation&.created_at&.iso8601
    }
  end

  # Bewusst ohne Bewertungen/Kommentare – die abgebende Seite sieht nur den Status.
  def status_payload(feedback)
    {
      game_id: feedback.game_id,
      team_id: feedback.team_id,
      done: true,
      submitted_at: feedback.created_at.iso8601
    }
  end
end
