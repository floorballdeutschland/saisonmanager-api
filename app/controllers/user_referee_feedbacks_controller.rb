# Team-seitiges Schiri-Feedback (TM/VM). Listet die feedback-pflichtigen,
# bereits gespielten Spiele der eigenen Mannschaften und nimmt je Spiel und Team
# genau eine Rückmeldung entgegen. Analog zu TeamGameDayConfirmationsController.
#
# Die abgebende Seite sieht bewusst nur den Status (offen / erledigt) – die
# Inhalte (Bewertungen, Kommentare) sind ausschließlich in der Schiriverwaltung
# am Schiri-Profil sichtbar.
class UserRefereeFeedbacksController < ApplicationController
  before_action :authenticate_user

  # Frühestens 24 h nach Anpfiff ausfüllbar ("24–48 h nach dem Spiel und
  # keinesfalls vorher").
  FILLABLE_AFTER_HOURS = 24
  # Wie weit zurück gespielte Spiele in der Übersicht erscheinen.
  LOOKBACK_DAYS = 120

  # GET /api/v2/user/referee_feedbacks
  def index
    return render json: [] if managed_team_ids.empty?

    games = eligible_games
    feedbacks = RefereeFeedback
                .where(game_id: games.map(&:id))
                .index_by { |f| [f.game_id, f.team_id] }

    payload = games.flat_map do |game|
      participating_managed_teams(game).map do |team|
        game_feedback_json(game, team, feedbacks[[game.id, team.id]])
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

    # Idempotent: bereits abgegeben → unverändert als "erledigt" zurückgeben.
    existing = RefereeFeedback.find_by(game: game, team: team)
    return render json: status_payload(existing) if existing

    fillable = fillable_from(game)
    if fillable.nil? || Time.current < fillable
      return render json: { error: 'Feedback ist erst 24 Stunden nach dem Spiel möglich.' },
                    status: :unprocessable_entity
    end

    referees = game.nominated_referees
    feedback = RefereeFeedback.new(
      game: game,
      team: team,
      club_id: team.club_id,
      submitted_by_user_id: current_user.id,
      referee1_id: referees[0]&.id,
      referee2_id: referees[1]&.id,
      referee_names: referees.map { |r| "#{r.vorname} #{r.nachname}".strip }.join(' / ').presence,
      line_rating: params[:line_rating],
      line_comment: params[:line_comment].to_s.strip.presence,
      communication_rating: params[:communication_rating],
      communication_comment: params[:communication_comment].to_s.strip.presence,
      general_comment: params[:general_comment].to_s.strip.presence
    )

    if feedback.save
      render json: status_payload(feedback), status: :created
    else
      render json: { error: feedback.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue ActiveRecord::RecordNotUnique
    existing = RefereeFeedback.find_by(game: game, team: team)
    render json: status_payload(existing) if existing
  end

  private

  # Team-IDs, die der/die Benutzer:in als Teammanager (direkt) oder als
  # Vereinsmanager (alle Teams der eigenen Vereine) verantwortet.
  def managed_team_ids
    @managed_team_ids ||= begin
      ids = tm_team_ids.dup
      ids += Team.where(club_id: managed_club_ids).pluck(:id) if managed_club_ids.present?
      ids.uniq
    end
  end

  def tm_team_ids
    @tm_team_ids ||= Array(current_user.permission_hash[:tm]).map(&:to_i)
  end

  def managed_club_ids
    @managed_club_ids ||= Array(current_user.permission_hash[:vm]).map(&:to_i)
  end

  # Bereits gespielte Spiele feedback-pflichtiger Ligen, an denen eine eigene
  # Mannschaft beteiligt ist (Lookback-Fenster, nicht in der Zukunft).
  def eligible_games
    Game
      .joins(game_day: :league)
      .includes(:home_team, :guest_team, game_day: :league)
      .where(leagues: { referee_feedback_enabled: true })
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

  # Frühester Abgabezeitpunkt (Anpfiff + 24 h). nil, wenn sich kein Zeitpunkt
  # ermitteln lässt (kein Datum). Fehlt nur die Startzeit, wird vom Tagesbeginn
  # des Spieltags gerechnet, damit ein Spiel ohne gepflegte Uhrzeit nicht crasht.
  def fillable_from(game)
    base = game_start(game)
    base && base + FILLABLE_AFTER_HOURS.hours
  end

  def game_start(game)
    return nil if game.game_day&.date.blank?

    tz = ActiveSupport::TimeZone['Europe/Berlin']
    tz.parse("#{game.game_day.date} #{game.start_time}".strip)
  rescue ArgumentError, TypeError
    nil
  end

  def game_feedback_json(game, team, feedback)
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
      referees: game.nominated_referees.map { |r| "#{r.vorname} #{r.nachname}".strip },
      fillable_from: fillable_from(game)&.iso8601,
      done: feedback.present?,
      submitted_at: feedback&.created_at&.iso8601
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
