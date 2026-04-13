module Admin
  class RefereesController < ApplicationController
    before_action :authorize_rsk!
    before_action :set_referee, only: %i[show update destroy games]

    # GET /api/v2/admin/referees
    def index
      referees = Referee.all

      referees = referees.search(params[:q]) if params[:q].present?
      referees = referees.by_landesverband(params[:landesverband]) if params[:landesverband].present?
      referees = referees.by_lizenzstufe(params[:lizenzstufe]) if params[:lizenzstufe].present?
      referees = referees.active if params[:active] == 'true'

      referees = referees.order(:nachname, :vorname)

      render json: referees.map { |r| referee_json(r) }
    end

    # GET /api/v2/admin/referees/:id
    def show
      render json: referee_json(@referee, full: true)
    end

    # POST /api/v2/admin/referees
    def create
      referee = Referee.new(referee_params)

      if referee.save
        render json: referee_json(referee, full: true), status: :created
      else
        render json: { errors: referee.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/referees/:id
    def update
      if @referee.update(referee_params)
        render json: referee_json(@referee, full: true)
      else
        render json: { errors: @referee.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/referees/:id
    def destroy
      @referee.destroy
      head :no_content
    end

    # GET /api/v2/admin/referees/:id/games
    def games
      season_id = params[:season_id]
      games = @referee.games(season_id: season_id)
                      .includes(:home_team, :guest_team, game_day: :league)
                      .joins(:game_day)
                      .order('game_days.date DESC')

      render json: games.map { |g| game_summary(g) }
    end

    # GET /api/v2/admin/referees/incorrect_assignments
    def incorrect_assignments
      season_id = params[:season_id] || Setting.current_season_id
      games = Referee.incorrect_assignments(season_id: season_id)

      render json: games.map { |g| game_summary(g, include_refs: true) }
    end

    private

    def set_referee
      @referee = Referee.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Schiedsrichter nicht gefunden' }, status: :not_found
    end

    def referee_params
      params.require(:referee).permit(
        :lizenznummer, :vorname, :nachname, :geburtsdatum, :email,
        :verein, :landesverband, :game_operation_id,
        :lizenzstufe, :gueltigkeit, :zusatzqualifikation, :gueltigkeit_z
      )
    end

    def authorize_rsk!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      if ph[:rsk].present?
        # RSK-Benutzer: immer erlaubt (GO-Filterung folgt in Phase 2)
        return
      end

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def referee_json(referee, full: false)
      data = {
        id: referee.id,
        lizenznummer: referee.lizenznummer,
        vorname: referee.vorname,
        nachname: referee.nachname,
        verein: referee.verein,
        landesverband: referee.landesverband,
        lizenzstufe: referee.lizenzstufe,
        gueltigkeit: referee.gueltigkeit&.strftime('%d.%m.%Y'),
        active: referee.gueltigkeit.present? && referee.gueltigkeit >= Date.today
      }

      if full
        data.merge!(
          geburtsdatum: referee.geburtsdatum&.strftime('%d.%m.%Y'),
          email: referee.email,
          game_operation_id: referee.game_operation_id,
          zusatzqualifikation: referee.zusatzqualifikation,
          gueltigkeit_z: referee.gueltigkeit_z&.strftime('%d.%m.%Y')
        )
      end

      data
    end

    def game_summary(game, include_refs: false)
      data = {
        id: game.id,
        game_number: game.game_number,
        date: game.game_day.date,
        home_team: game.home_team&.name,
        guest_team: game.guest_team&.name,
        league: game.league&.name,
        season_id: game.game_day.league&.season_id,
        result: game.result_string
      }

      if include_refs
        data[:referee1] = game.referee1_string
        data[:referee2] = game.referee2_string
      end

      data
    end
  end
end
