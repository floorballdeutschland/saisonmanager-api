module Admin
  class RefereesController < ApplicationController
    before_action :authorize_referee_access!
    before_action :set_referee, only: %i[show update destroy games wallet_pass club_stats merge]

    # GET /api/v2/admin/referees
    def index
      referees = Referee.includes(club: :state_association,
                                  referee_qualifications: :referee_qualification_type)

      referees = scope_to_permitted_referees(referees)

      referees = referees.search(params[:q]) if params[:q].present?
      referees = referees.by_landesverband(params[:landesverband]) if params[:landesverband].present?
      referees = referees.by_lizenzstufe(params[:lizenzstufe]) if params[:lizenzstufe].present?
      referees = referees.active if params[:active] == 'true'

      sort_col = params[:sort] == 'lizenznummer' ? 'lizenznummer' : 'nachname'
      sort_dir = params[:sort_dir] == 'desc' ? 'DESC' : 'ASC'
      referees = if sort_col == 'lizenznummer'
                   referees.order(Arel.sql("lizenznummer #{sort_dir} NULLS LAST"))
                 else
                   referees.order(Arel.sql("nachname #{sort_dir}, vorname #{sort_dir}"))
                 end

      render json: referees.map { |r| referee_json(r) }
    end

    # GET /api/v2/admin/referees/:id
    def show
      return forbidden_response unless can_access_referee?(@referee)

      render json: referee_json(@referee, full: true)
    end

    # POST /api/v2/admin/referees
    def create
      return forbidden_response unless can_create_referee?

      referee = Referee.new(safe_referee_params)
      referee.game_operation_id = assigned_game_operation_id if restricted_user? && referee.game_operation_id.blank?

      if referee.save
        sync_qualifications(referee) if can_edit_full?
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
      return forbidden_response unless can_access_referee?(@referee)

      @referee.assign_attributes(safe_referee_params)
      license_fields_changed = (@referee.changed & %w[lizenznummer gueltigkeit lizenzstufe]).any?
      notify = @referee.email.present? && license_fields_changed && !@referee.guest?

      if @referee.save
        sync_qualifications(@referee) if can_edit_full?
        RefereeMailer.license_notification(@referee, action: :updated).deliver_later if notify
        render json: referee_json(@referee.reload, full: true)
      else
        render json: { errors: @referee.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/referees/:id
    def destroy
      return forbidden_response unless can_edit_full?

      @referee.destroy
      head :no_content
    end

    # POST /api/v2/admin/referees/:id/merge
    def merge
      return forbidden_response unless can_access_referee?(@referee)

      secondary = Referee.find_by(id: params[:secondary_id])
      return render json: { message: 'Secondary-Schiedsrichter nicht gefunden.' }, status: :not_found unless secondary
      return forbidden_response unless can_access_referee?(secondary)

      secondary.merge_into!(@referee)
      render json: { message: 'Schiedsrichter erfolgreich zusammengeführt.', master_id: @referee.id }
    rescue ArgumentError => e
      render json: { message: e.message }, status: :unprocessable_entity
    end

    # POST /api/v2/admin/referees/:id/wallet_pass
    def wallet_pass
      return forbidden_response unless can_access_referee?(@referee)

      result = PassmeisterService.create_or_update_pass(@referee)
      pass_url = result.dig('pass', 'walletSafe', 'urls', 'default')

      if pass_url.blank?
        Rails.logger.warn(
          "Passmeister: keine URL für Referee #{@referee.id} (Lizenz #{@referee.lizenznummer}). " \
          "Response-Top-Level-Keys: #{result.keys.inspect}, " \
          "walletSafe-Keys: #{result.dig('pass', 'walletSafe')&.keys.inspect}"
        )
        render json: { error: 'Passmeister lieferte keine Pass-URL' }, status: :unprocessable_entity
        return
      end

      @referee.update_columns(
        wallet_pass_issued_at: Time.current,
        wallet_pass_url: pass_url
      )

      RefereeMailer.wallet_pass_issued(@referee, pass_url).deliver_later if @referee.email.present?

      render json: { url: pass_url }
    rescue PassmeisterService::Error => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # GET /api/v2/admin/referees/:id/games
    def games
      return forbidden_response unless can_access_referee?(@referee)

      season_id = params[:season_id]
      games = @referee.games(season_id: season_id)
                      .includes(:home_team, :guest_team, game_day: :league)
                      .joins(:game_day)
                      .order('game_days.date DESC')

      render json: games.map { |g| game_summary(g) }
    end

    # GET /api/v2/admin/referees/:id/club_stats
    def club_stats
      return forbidden_response unless can_access_referee?(@referee)

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

    # GET /api/v2/admin/referees/next_lizenznummer
    def next_lizenznummer
      return forbidden_response unless can_create_referee?

      max = Referee.where(guest: false).maximum(:lizenznummer) || 0
      render json: { next_lizenznummer: max + 1 }
    end

    # GET /api/v2/admin/referees/incorrect_assignments
    def incorrect_assignments
      return forbidden_response unless can_edit_full?

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

    def restricted_referee_params
      params.require(:referee).permit(
        :vorname, :nachname, :geburtsdatum, :email,
        :strasse, :hausnummer, :plz, :ort, :partner_lizenznummer, :guest
      )
    end

    def safe_referee_params
      can_edit_full? ? referee_params : restricted_referee_params
    end

    def sync_qualifications(referee)
      return unless params[:referee][:qualifications]

      incoming = Array(params[:referee][:qualifications]).filter_map do |q|
        type_id = q[:qualification_type_id].to_i
        next unless type_id.positive?

        valid_until = q[:valid_until].presence ? Date.strptime(q[:valid_until], '%d.%m.%Y') : nil
        { qualification_type_id: type_id, valid_until: valid_until }
      rescue Date::Error
        nil
      end

      ActiveRecord::Base.transaction do
        referee.referee_qualifications.destroy_all
        incoming.each do |attrs|
          referee.referee_qualifications.create!(
            referee_qualification_type_id: attrs[:qualification_type_id],
            valid_until: attrs[:valid_until]
          )
        end
      end
    end

    def authorize_referee_access!
      ph = current_user.permission_hash
      return if ph[:admin].present?
      return if ph[:rsk].present?
      return if ph[:sbk].present?
      return if ph[:vm].present?

      forbidden_response
    end

    def forbidden_response
      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def scope_to_permitted_referees(referees)
      ph = current_user.permission_hash
      return referees if ph[:admin].present?
      return referees if ph[:rsk].present? && ph[:rsk].include?(0)
      return referees if ph[:sbk].present? && ph[:sbk].include?(0)

      if ph[:rsk].present? || ph[:sbk].present?
        go_ids = ((ph[:rsk] || []) + (ph[:sbk] || [])).reject { |id| id.zero? }.uniq
        club_ids = lv_club_ids(go_ids)
        referees.where(club_id: club_ids).or(referees.where(game_operation_id: go_ids))
      elsif ph[:vm].present?
        referees.where(club_id: ph[:vm])
      else
        referees.none
      end
    end

    def can_access_referee?(referee)
      ph = current_user.permission_hash
      return true if ph[:admin].present?
      return true if ph[:rsk].present? && ph[:rsk].include?(0)
      return true if ph[:sbk].present? && ph[:sbk].include?(0)

      if ph[:rsk].present? || ph[:sbk].present?
        go_ids = ((ph[:rsk] || []) + (ph[:sbk] || [])).reject { |id| id.zero? }.uniq
        lv_club_ids(go_ids).include?(referee.club_id) || go_ids.include?(referee.game_operation_id)
      elsif ph[:vm].present?
        ph[:vm].include?(referee.club_id)
      else
        false
      end
    end

    def lv_club_ids(go_ids)
      sa_ids = GameOperation.where(id: go_ids).pluck(:state_association_id).compact
      Club.where(state_association_id: sa_ids).pluck(:id)
    end

    def can_create_referee?
      ph = current_user.permission_hash
      ph[:admin].present? || ph[:rsk].present?
    end

    def can_edit_full?
      ph = current_user.permission_hash
      ph[:admin].present? || (ph[:rsk].present? && ph[:rsk].include?(0))
    end

    def restricted_user?
      !can_edit_full?
    end

    # Returns the single go_id for an LV-RSK user (used to auto-assign on create)
    def assigned_game_operation_id
      ph = current_user.permission_hash
      ph[:rsk]&.reject { |id| id.zero? }&.first
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
