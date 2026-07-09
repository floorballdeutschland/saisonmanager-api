class TeamsController < ApplicationController
  skip_before_action :authenticate_user, only: %i[show stats]
  before_action :authenticate_public_request, only: %i[show stats]

  # GET /teams
  def index
    @teams = Team.all

    render json: @teams
  end

  # GET /teams/1.json
  def show
    games = Game.by_team_id(params[:id])

    respond_to do |format|
      format.ics do
        ical = ::Icalendar::Calendar.new
        events = games.map(&:ical)
        events.each { |event| ical.add_event(event) }

        require 'icalendar/tzinfo'
        tzid = 'Europe/Berlin'
        tz = TZInfo::Timezone.get tzid
        timezone = tz.ical_timezone events.first.dtstart
        ical.add_timezone timezone

        ical.append_custom_property('METHOD', 'REQUEST')
        ical.publish

        render plain: ical.to_ical
      end
    end
  end

  def stats
    team = Team.find(params[:id])

    # All leagues this team participates in (main league + cup leagues)
    leagues = team.leagues.where(season_id: Setting.current_season_id).to_a
    primary_league = leagues.first

    # Evaluate scorer directly from the team's current-season ended games
    current_season_games = Game.by_team_id(team.id)
                               .where(ended: true)
                               .joins(game_day: :league)
                               .where(leagues: { season_id: Setting.current_season_id })

    team_scorer_data = {}
    current_season_games.each do |game|
      next if game.result.nil?

      begin
        game_score = game.evaluate_scorer
        game_score.each do |player_id, score|
          next unless score[:team_id] == team.id

          if team_scorer_data[player_id]
            %i[games goals assists penalty_2 penalty_2and2 penalty_5 penalty_10
               penalty_ms_tech penalty_ms_full penalty_ms1 penalty_ms2 penalty_ms3].each do |k|
              team_scorer_data[player_id][k] = (team_scorer_data[player_id][k] || 0) + (score[k] || 0)
            end
          else
            team_scorer_data[player_id] = score.dup
          end
        end
      rescue StandardError => e
        Rails.logger.warn("evaluate_scorer failed for game #{game.id}: #{e.message}")
      end
    end

    team_scorer = team_scorer_data.values

    # Resolve player names
    player_ids = team_scorer.map { |s| s[:player_id] }
    players = Player.where(id: player_ids).index_by(&:id)

    scorer_list = team_scorer
                  .sort_by { |s| [-(s[:goals] + s[:assists]), -s[:goals], -s[:games]] }
                  .map do |s|
      player = players[s[:player_id]]
      next if player.nil?
      {
        player_id:    s[:player_id],
        first_name:   player.first_name,
        last_name:    player.last_name,
        games:        s[:games],
        goals:        s[:goals],
        assists:      s[:assists],
        scorer_points: s[:goals] + s[:assists],
        penalty_minutes: (s[:penalty_2] * 2) + (s[:penalty_2and2] * 4) +
                         (s[:penalty_5] * 5) + (s[:penalty_10] * 10) +
                         (s[:penalty_ms_tech] + s[:penalty_ms_full] +
                          s[:penalty_ms1] + s[:penalty_ms2] + s[:penalty_ms3]) * 25
      }
    end.compact

    # Recent results (last 10 ended games across all leagues, ordered by game day date)
    recent_games = Game.by_team_id(team.id)
                       .where(ended: true)
                       .joins(game_day: :league)
                       .where(leagues: { season_id: Setting.current_season_id })
                       .includes(game_day: :league)
                       .order('game_days.date DESC')
                       .limit(10)
                       .map do |g|
      result = g.result
      {
        game_id:            g.id,
        game_number:        g.game_number,
        home_team_name:     g.home_team_name,
        home_team_logo:     g.home_team&.logo_small_url_fallback,
        guest_team_name:    g.guest_team_name,
        guest_team_logo:    g.guest_team&.logo_small_url_fallback,
        home_goals:         result&.dig(:home_goals),
        guest_goals:        result&.dig(:guest_goals),
        date:               g.game_day.date,
        league_name:        g.game_day.league.name,
        league_short_name:  g.game_day.league.short_name
      }
    end

    # Upcoming games (next 10 across all leagues, not yet started)
    upcoming_games = Game.by_team_id(team.id)
                         .where(started: false)
                         .joins(game_day: :league)
                         .where(leagues: { season_id: Setting.current_season_id })
                         .where('game_days.date >= ?', Date.today)
                         .includes(game_day: :league)
                         .order('game_days.date ASC')
                         .limit(10)
                         .map do |g|
      {
        game_id:            g.id,
        game_number:        g.game_number,
        home_team_name:     g.home_team_name,
        home_team_logo:     g.home_team&.logo_small_url_fallback,
        guest_team_name:    g.guest_team_name,
        guest_team_logo:    g.guest_team&.logo_small_url_fallback,
        date:               g.game_day.date,
        start_time:         g.start_time,
        league_name:        g.game_day.league.name,
        league_short_name:  g.game_day.league.short_name
      }
    end

    leagues_info = leagues.map do |l|
      {
        id: l.id,
        name: l.name,
        short_name: l.short_name,
        game_operation_slug: l.game_operation.slug
      }
    end

    team_info = if primary_league
                  {
                    id: team.id,
                    name: team.name,
                    short_name: team.short_name,
                    logo_url: team.logo_url_fallback,
                    logo_small: team.logo_small_url_fallback,
                    league_id: primary_league.id,
                    league_name: primary_league.name,
                    leagues: leagues_info,
                    game_operation_id: primary_league.game_operation.id,
                    game_operation_name: primary_league.game_operation.name,
                    game_operation_short_name: primary_league.game_operation.short_name,
                    game_operation_slug: primary_league.game_operation.slug
                  }
                else
                  { id: team.id, name: team.name, short_name: team.short_name, league_name: nil, leagues: [] }
                end

    render json: {
      team:           team_info,
      scorer:         scorer_list,
      recent_games:,
      upcoming_games:,
      totals: {
        games:           scorer_list.sum { |s| s[:games] } / [scorer_list.size, 1].max, # avg
        goals:           scorer_list.sum { |s| s[:goals] },
        assists:         scorer_list.sum { |s| s[:assists] },
        penalty_minutes: scorer_list.sum { |s| s[:penalty_minutes] }
      }
    }
  end

  # Team-Details inkl. Kontaktdaten (full_hash(true)) – nur Admin/SBK des
  # Spielbetriebs sowie VM/TM der eigenen Mannschaft.
  def admin_get_team
    if current_user
      team = Team.find(params[:id])

      if can_read_admin_team?(team)
        render json: team.full_hash(true)
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_team_update
    if current_user
      create_modus = params[:id].zero?
      # check: game operation permission if create_modus
      #   has: create team for that go?
      #   else : unpermitted!
      # check: league permission unless create_modus
      #   has: update league for that league?
      #   else : unpermitted!
      l = League.find(params[:league_id])

      if create_modus && League.find(params[:league_id])&.game_operation&.user_permissions(current_user)&.include?(:create_team) # create
        if params[:team][:cup_leagues].present?
          valid_ids = League.where(game_operation_id: l.game_operation_id).pluck(:id)
          invalid = Array(params[:team][:cup_leagues]).map(&:to_i) - valid_ids
          return render json: { errors: ["Ungültige Liga-IDs: #{invalid.join(', ')}"] }, status: :unprocessable_entity if invalid.any?
        end

        tp = team_params
        team = Team.create(tp)

        render json: team, status: :created
      elsif !create_modus && Team.find(params[:id])&.user_permissions(current_user)&.include?(:update_team) # update
        team = Team.find(params[:id])
        if params[:team][:cup_leagues].present?
          valid_ids = League.where(game_operation_id: team.league.game_operation_id).pluck(:id)
          invalid = Array(params[:team][:cup_leagues]).map(&:to_i) - valid_ids
          return render json: { errors: ["Ungültige Liga-IDs: #{invalid.join(', ')}"] }, status: :unprocessable_entity if invalid.any?
        end
        if team.update(team_params)
          render json: team
        else
          render json: team.errors, status: :unprocessable_entity
        end
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def license_list
    team = Team.find(params[:id])

    hash = league.short_hash true

    render json: team.licenses(false, true, :short)
  end

  def admin_upload_logo
    if current_user
      team = Team.find(params[:id])

      unless team.user_permissions(current_user).include?(:update_team)
        return render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

      unless params[:logo].present?
        return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity
      end

      team.logo.attach(params[:logo])
      render json: { logo_url: team.logo_url, logo_small_url: team.logo_small_url }
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def team_params
    params.require(:team).permit(:club_id, :contact_email, :contact_person, :league_id, :name, :short_name, :syndicate,
                                 syndicate_clubs: [], cup_leagues: [])
  end

  private

  def can_read_admin_team?(team)
    ph = current_user.permission_hash
    go_id = team.league&.game_operation_id.to_i
    return true if ph[:admin].to_a.intersect?([0, go_id]) || ph[:sbk].to_a.intersect?([0, go_id])
    return true if ph[:vm].present? && ph[:vm].intersect?(team.all_club_ids)

    ph[:tm].present? && ph[:tm].include?(team.id)
  end
end
