class LeaguesController < ApplicationController
  skip_before_action :authenticate_user, except: [:admin_league_index]

  # GET /leagues
  def index
    @leagues = League.all.order(season_id: :desc, game_operation_id: :asc).order('order_key::int')
    @gos = {}
    GameOperation.all.each { |go| @gos[go.id] = go }
  end

  def admin_league_index
    if current_user
      result = League.admin_user_leagues(current_user)

      render json: result
    else
      render json: { error: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_league_team_index
    if current_user
      league = League.find(params[:id])

      if league
        render json: league.hash_with_teams
      else
        render json: { error: 'Keine passende Liga gefunden.' }, status: :not_found
      end
    else
      render json: { error: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_league_permissions
    if current_user
      result = League.admin_league_permissions(current_user)

      render json: result
    else
      render json: { error: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_league_update
    if current_user
      create_modus = params[:id].zero?
      # check: game operation permission if create_modus
      #   has: create league for that go?
      #   else : unpermitted!
      # check: league permission unless create_modus
      #   has: update league for that league?
      #   else : unpermitted!
      if create_modus && GameOperation.find(params[:game_operation_id])&.user_permissions(current_user)&.include?(:create_league) # create

        lp = league_params
        lp[:season_id] = Setting.current_season
        tp[:legacy_league] = false
        league = League.create(lp)

        render json: league, status: :created
      elsif !create_modus && League.find(params[:id])&.user_permissions(current_user)&.include?(:update_league) # update
        # update
        league = League.find(params[:id])
        if league.update(league_params)
          render json: league
        else
          render json: league.errors, status: :unprocessable_entity
        end
      else
        render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { error: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_league_classes
    if current_user
      render json: Setting.current.league_classes.map { |k, v|
                     v['id'] = k
                     v
                   }
    else
      render json: { error: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_game_schedule
    if current_user
      league = League.find(params[:id])

      if league
        render json: league.game_days.includes(:arena, :club, :games).map { |gd| gd.full_hash(true) }
      else
        render json: { error: 'Keine passende Liga gefunden.' }, status: :not_found
      end
    else
      render json: { error: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  # GET /leagues/1
  def show
    league = League.find(params[:id])

    render json: league.full_hash(true)
  end

  # GET /leagues/1/schedule
  api :GET, '/leagues/:id/schedule.json'
  param :id, :number,
        required: true, desc: 'league id'
  # short_description 'Prints the game schedule for league :id.'
  description <<-EOS
      Prints the game schedule for league :id. If the game was already played a result_string is included.
  EOS
  def schedule
    @league = League.find(params[:id])

    render json: @league.schedule
  end

  # GET /leagues/1/game_days/15/schedule
  def game_day_schedule
    @league = League.find(params[:id])

    render json: @league.game_day_schedule(params[:game_day_number])
  end

  # GET /leagues/1/game_days/current/schedule
  def current_schedule
    @league = League.find(params[:id])

    render json: @league.current_schedule
  end

  # GET /leagues/1/scorer
  api :GET, '/leagues/:id/scorer.json'
  param :id, :number,
        required: true, desc: 'league id'
  # short_description 'Prints the scorer table for league :id.'
  description <<-EOS
      Prints the scorer table for league :id.
  EOS
  def scorer
    @league = League.find(params[:id])

    render json: @league.scorer
  end

  # GET /leagues/1/table
  api :GET, '/leagues/:id/table.json'
  param :id, :number,
        required: true, desc: 'league id'
  # short_description 'Prints the table for league :id.'
  description <<-EOS
      Prints the table for league :id.
  EOS
  def table
    @league = League.find(params[:id])

    render json: @league.table
  end

  def license_list
    @league = League.find(params[:id])
  end

  def meta
    @league = League.find(params[:id])

    render json: @league.meta_item
  end

  def league_params
    params.require(:league).permit(:before_deadline, :deadline, :female, :game_operation_id,
                                   :league_category_id, :league_class_id, :league_system_id, :name, :order_key,
                                   :short_name, :enable_scorer, :field_size, :league_modus, :league_id_preseason,
                                   :league_id_preround, :has_preround, :preround_point_modus, :preround_scorer_modus,
                                   :table_modus, :periods, :period_length, :overtime_length)
  end
end
