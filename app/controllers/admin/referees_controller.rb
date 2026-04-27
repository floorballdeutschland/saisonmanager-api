module Admin
  class RefereesController < ApplicationController
    before_action :authorize_rsk!
    before_action :set_referee, only: %i[show update destroy games wallet_pass club_stats]

    # GET /api/v2/admin/referees
    def index
      referees = Referee.includes(club: :state_association,
                                  referee_qualifications: :referee_qualification_type)

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
        sync_qualifications(referee)
        if referee.email.present? && referee.lizenznummer.present? && !referee.guest?
          RefereeMailer.license_notification(referee, action: :created).deliver_later
        end
        render json: referee_json(referee.reload, full: true), status: :created
      else
        render json: { errors: referee.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/referees/:id
    def update
      @referee.assign_attributes(referee_params)
      license_fields_changed = (@referee.changed & %w[lizenznummer gueltigkeit lizenzstufe]).any?
      notify = @referee.email.present? && license_fields_changed && !@referee.guest?

      if @referee.save
        sync_qualifications(@referee)
        RefereeMailer.license_notification(@referee, action: :updated).deliver_later if notify
        render json: referee_json(@referee.reload, full: true)
      else
        render json: { errors: @referee.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/referees/:id
    def destroy
      @referee.destroy
      head :no_content
    end

    # POST /api/v2/admin/referees/:id/wallet_pass
    def wallet_pass
      result = PassmeisterService.create_or_update_pass(@referee)
      pass_url = result['passUrl'] || result['url'] || result['passDownloadUrl']

      @referee.update_columns(
        wallet_pass_issued_at: Time.current,
        wallet_pass_url: pass_url
      )

      render json: { url: pass_url }
    rescue RuntimeError => e
      render json: { error: e.message }, status: :unprocessable_entity
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

    # GET /api/v2/admin/referees/:id/club_stats
    def club_stats
      season_id = params[:season_id]

      games = @referee.games(season_id: season_id)
                      .includes(
                        game_day: :league,
                        home_team: :club,
                        guest_team: :club
                      )

      counts = Hash.new(0)
      club_names = {}

      games.each do |game|
        s = game.game_day.league&.season_id
        [game.home_team&.club, game.guest_team&.club].compact.each do |club|
          key = [club.id, s]
          counts[key] += 1
          club_names[club.id] = club.name
        end
      end

      result = counts.map do |(club_id, s), count|
        { club_id:, club_name: club_names[club_id], season_id: s, game_count: count }
      end

      result.sort_by! { |r| [-r[:game_count], r[:club_name].to_s] }

      render json: result
    end

    # GET /api/v2/admin/referees/incorrect_assignments
    def incorrect_assignments
      season_id = params[:season_id] || Setting.current_season_id
      games = Referee.incorrect_assignments(season_id: season_id)

      render json: games.map { |g| game_summary(g, include_refs: true) }
    end

    private

    def set_referee
      @referee = Referee.includes(club: :state_association,
                                  referee_qualifications: :referee_qualification_type)
                        .find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Schiedsrichter nicht gefunden' }, status: :not_found
    end

    def referee_params
      params.require(:referee).permit(
        :lizenznummer, :vorname, :nachname, :geburtsdatum, :email,
        :club_id, :game_operation_id,
        :lizenzstufe, :gueltigkeit,
        :strasse, :hausnummer, :plz, :ort, :partner_lizenznummer, :guest
      )
    end

    def sync_qualifications(referee)
      return unless params[:referee][:qualifications]

      incoming = Array(params[:referee][:qualifications]).map do |q|
        {
          qualification_type_id: q[:qualification_type_id].to_i,
          valid_until: q[:valid_until].presence
        }
      end.select { |q| q[:qualification_type_id].positive? }

      referee.referee_qualifications.destroy_all

      incoming.each do |attrs|
        valid_until = attrs[:valid_until].present? ? Date.strptime(attrs[:valid_until], '%d.%m.%Y') : nil
        referee.referee_qualifications.create!(
          referee_qualification_type_id: attrs[:qualification_type_id],
          valid_until: valid_until
        )
      rescue Date::Error
        nil
      end
    end

    def authorize_rsk!
      ph = current_user.permission_hash
      return if ph[:admin].present?
      return if ph[:rsk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def referee_json(referee, full: false)
      data = {
        id: referee.id,
        lizenznummer: referee.lizenznummer,
        lizenznummer_display: referee.lizenznummer_display,
        guest: referee.guest,
        vorname: referee.vorname,
        nachname: referee.nachname,
        club_id: referee.club_id,
        club_name: referee.club&.name,
        landesverband: referee.landesverband,
        lizenzstufe: referee.lizenzstufe,
        gueltigkeit: referee.gueltigkeit&.strftime('%d.%m.%Y'),
        active: !referee.guest? && referee.gueltigkeit.present? && referee.gueltigkeit >= Date.today,
        wallet_pass_issued_at: referee.wallet_pass_issued_at&.iso8601,
        wallet_pass_url: referee.wallet_pass_url
      }

      if full
        data.merge!(
          geburtsdatum: referee.geburtsdatum&.strftime('%d.%m.%Y'),
          email: referee.email,
          game_operation_id: referee.game_operation_id,
          strasse: referee.strasse,
          hausnummer: referee.hausnummer,
          plz: referee.plz,
          ort: referee.ort,
          partner_lizenznummer: referee.partner_lizenznummer,
          qualifications: referee.referee_qualifications.map { |q| qualification_json(q) }
        )
      end

      data
    end

    def qualification_json(q)
      {
        id: q.id,
        qualification_type_id: q.referee_qualification_type_id,
        qualification_type_name: q.referee_qualification_type&.name,
        valid_until: q.valid_until&.strftime('%d.%m.%Y')
      }
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
