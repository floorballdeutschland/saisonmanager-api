class TeamsController < ApplicationController
  skip_before_action :authenticate_user, only: %i[show stats]

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
    league = team.league

    # All scorer data for the league, filtered to this team
    team_scorer = if league
                    league.evaluate_scorer.values.select { |s| s[:team_id] == team.id }
                  else
                    []
                  end

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

    # Recent results (last 5 ended games)
    recent_games = Game.by_team_id(team.id)
                       .where(ended: true)
                       .order(Arel.sql("NULLIF(game_number, '')::integer DESC NULLS LAST"))
                       .limit(5)
                       .map do |g|
      result = g.result
      {
        game_id:         g.id,
        game_number:     g.game_number,
        home_team_name:  g.home_team_name,
        guest_team_name: g.guest_team_name,
        home_goals:      result&.dig(:home_goals),
        guest_goals:     result&.dig(:guest_goals),
        date:            g.date
      }
    end

    render json: {
      team:    team.full_hash,
      scorer:  scorer_list,
      recent_games:,
      totals: {
        games:           scorer_list.sum { |s| s[:games] } / [scorer_list.size, 1].max, # avg
        goals:           scorer_list.sum { |s| s[:goals] },
        assists:         scorer_list.sum { |s| s[:assists] },
        penalty_minutes: scorer_list.sum { |s| s[:penalty_minutes] }
      }
    }
  end

  def admin_get_team
    if current_user
      team = Team.find(params[:id])

      if team
        render json: team.full_hash(true)
      else
        render json: { message: 'Keine passendes Team gefunden.' }, status: :not_found
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

        tp = team_params
        team = Team.create(tp)

        render json: team, status: :created
      elsif !create_modus && Team.find(params[:id])&.user_permissions(current_user)&.include?(:update_team) # update
        # update
        team = Team.find(params[:id])
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
                                 syndicate_clubs: [])
  end
end
