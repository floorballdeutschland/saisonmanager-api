# Selfservice rund um den Beobachtungsbogen des Schiedsrichtercoaches.
#
# Zwei Rollen desselben Kontos, deshalb ein Controller:
#   * als Coach – Spiele finden (#games), Bogen abgeben (#create), eigene Bögen
#     wiederfinden (#index)
#   * als beobachtete Person – erhaltene Rückmeldungen lesen (#received)
#
# Anders als beim Vereins-Feedback sieht die beobachtete Person den vollen Text.
# Genau dafür gibt es den Bogen: Ein Coaching, das die betroffene Person nicht
# lesen kann, ist keines.
class RefereeObservationsController < ApplicationController
  before_action :authenticate_user
  before_action :require_referee_account

  # Wie weit zurück Spiele zur Auswahl angeboten werden.
  LOOKBACK_DAYS = 120

  # GET /api/v2/referee/observations
  # Eigene Bögen als Coach, auch zurückgenommene (siehe RefereeObservationPolicy).
  def index
    observations = RefereeObservation
                   .for_coach(@referee.id)
                   .includes(:ratings, game: { game_day: { league: :game_operation } })
                   .order(submitted_at: :desc)

    render json: observations.map { |o| observation_json(o) }
  end

  # GET /api/v2/referee/observations/games
  # Spiele, zu denen die angemeldete Person einen Bogen abgeben darf, mit
  # vorbelegtem Gespann. Bereits abgegebene Bögen sind markiert, damit die
  # Auswahl nicht in einen Fehler läuft.
  def games
    return render json: [] unless policy.coach_qualified?

    games = candidate_games.select { |game| policy.can_observe?(game) }
    existing = RefereeObservation.for_coach(@referee.id)
                                 .where(game_id: games.map(&:id))
                                 .index_by(&:game_id)

    render json: games.map { |game| candidate_json(game, existing[game.id]) }
  end

  # POST /api/v2/referee/observations
  def create
    game = Game.find(params[:game_id])
    return render json: { error: 'Nicht berechtigt' }, status: :forbidden unless policy.can_observe?(game)

    observation, error = RefereeObservationSubmission.new(
      game: game, coach: @referee, user: current_user, attributes: params
    ).call
    return render json: { error: error }, status: :unprocessable_entity if error

    RefereeObservationNotifier.new(observation).deliver if observation.previously_new_record?

    render json: observation_json(observation),
           status: observation.previously_new_record? ? :created : :ok
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # GET /api/v2/referee/observations/received
  # Rückmeldungen, die die angemeldete Person selbst erhalten hat. Zurückgenommene
  # Bögen (status hidden) sind hier bewusst nicht dabei.
  def received
    observations = RefereeObservation
                   .visible
                   .for_referee(@referee.id)
                   .includes(:ratings, :coach, game: { game_day: { league: :game_operation } })
                   .order(submitted_at: :desc)

    render json: observations.map { |o| observation_json(o, own_referee_id: @referee.id) }
  end

  private

  def policy
    @policy ||= RefereeObservationPolicy.new(current_user)
  end

  def require_referee_account
    @referee = current_user.referee
    render json: { error: 'Kein Schiedsrichterprofil gefunden' }, status: :forbidden unless @referee
  end

  # Vorauswahl für #games: Spiele mit Coach-Ansetzung auf die eigene Person plus –
  # in Spielbetrieben ohne personenscharfe Ansetzung – die Spiele des eigenen
  # Spielbetriebs. Die eigentliche Entscheidung trifft danach die Policy; diese
  # Query hält nur die Menge klein.
  def candidate_games
    today = RefereeObservationPolicy::ZONE.today
    assigned_game_ids = RefereeAssignment.where(coach_id: @referee.id).select(:game_id)

    Game
      .joins(game_day: :league)
      .includes(:home_team, :guest_team, game_day: { league: :game_operation })
      .where("TO_DATE(game_days.date, 'YYYY-MM-DD') BETWEEN ? AND ?", today - LOOKBACK_DAYS.days, today)
      .where('games.id IN (:assigned) OR leagues.game_operation_id IN (:go_ids)',
             assigned: assigned_game_ids, go_ids: own_game_operation_ids)
      .order('game_days.date DESC')
      .to_a
  end

  # -1 statt einer leeren Liste: `IN ()` ist kein gültiges SQL, und ein leeres
  # Array würde die ODER-Bedingung sonst zu `IN (NULL)` machen.
  def own_game_operation_ids
    ids = [@referee.club&.main_game_operation_id, @referee.game_operation_id].compact.uniq
    ids.presence || [-1]
  end

  def candidate_json(game, observation)
    referees, referee_names = game.feedback_referees
    {
      game_id: game.id,
      game_number: game.game_number,
      date: game.game_day&.date,
      start_time: game.start_time,
      home_team: game.home_team&.name,
      guest_team: game.guest_team&.name,
      league: game.league&.name,
      league_id: game.league&.id,
      league_level: league_level(game.league),
      game_operation_slug: game.league&.game_operation&.slug,
      assigned_as_coach: game.referee_assignment&.coach_id == @referee.id,
      referees: referees.each_with_index.map do |referee, index|
        { referee_id: referee.id, name: referee_names[index], position: index + 1 }
      end,
      done: observation.present?,
      observation_id: observation&.id
    }
  end

  # Ersetzt die Frage „Spielniveau" des Formulars: Ligamodus, Ligaklasse und
  # Altersklasse stehen an der Liga und werden nicht noch einmal erfasst.
  def league_level(league)
    return nil if league.nil?

    [league.league_modus, league.league_class_name, league.league_category_name, league.age_group]
      .map { |part| part.to_s.strip }.reject(&:empty?).uniq.join(' · ').presence
  end

  def observation_json(observation, own_referee_id: nil)
    RefereeObservationSerializer.new(observation, own_referee_id: own_referee_id).as_json
  end
end
