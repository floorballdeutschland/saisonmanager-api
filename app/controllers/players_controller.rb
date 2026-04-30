class PlayersController < ApplicationController
  before_action :set_player, only: %i[show update destroy]
  skip_before_action :authenticate_user, only: %i[transfers_public stats]
  before_action :authenticate_public_request, only: %i[transfers_public stats]

  # GET /players
  def index
    @players = Player.all.order(:last_name).order(:first_name).where("last_name != '' AND first_name != ''").order(:birthdate)
  end

  # GET /players/1
  def show; end

  def admin_players_index
    if current_user
      result = Player.admin_user_players(current_user, params[:club_id].to_i) || []

      render json: result
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def user_get_nations
    result = []

    Setting.current.nations.each do |k, v|
      item = {
        id: k,
        name: v['name'],
        eu: v['eu'],
        short_name: v['short_name']
      }

      result << item
    end

    render json: result
  end

  def global_search
    if current_user
      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:sbk].present?
        return render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

      q = params[:q].to_s.strip
      return render json: [] if q.length < 2

      term = "%#{q}%"
      players = Player.where(
        'last_name ILIKE :q OR first_name ILIKE :q OR concat(first_name, \' \', last_name) ILIKE :q OR concat(last_name, \', \', first_name) ILIKE :q',
        q: term
      ).order(:last_name, :first_name).limit(20)

      render json: players.map(&:search_hash)
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_player
    if current_user
      result = Player.find(params[:id])

      render json: result.full_hash(true, true, true)
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def request_license
    team = Team.find(params[:team_id])
    league = team.league

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].include?(team.club_id) || ph[:vm].intersection(team.syndicate_clubs).present?
              elsif ph[:tm].present?
                ph[:tm].include?(team.id)
              end

    return render json: { message: 'Keine Berechtigung für dieses Team!' }, status: :forbidden unless allowed

    result = :ok
    player = nil

    ActiveRecord::Base.transaction do
      player = Player.lock.find(params[:id])
      player.licenses ||= []

      if player.licenses.any? { |l| l['team_id'].to_i == team.id }
        result = :duplicate
        raise ActiveRecord::Rollback
      end

      new_license = {
        id: Digest::UUID.uuid_v4,
        team_id: team.id,
        league_class_id: league.league_class_id,
        male: !league.female,
        history: [{
          license_status_id: License::REQUESTED,
          created_by: current_user.id,
          created_at: Time.now
        }]
      }
      player.licenses << new_license

      result = :save_failed unless player.save
    end

    case result
    when :duplicate
      render json: { message: 'Der Spieler hat schon einen Lizenzantrag für dieses Team' },
             status: :unprocessable_entity
    when :save_failed
      render json: { message: player.errors }, status: :unprocessable_entity
    else
      render json: { success: true }
    end
  end

  def handle_license_request
    player = Player.find(params[:id])
    ph = current_user.permission_hash

    if (ph[:admin].present? || ph[:sbk].present?) && player.present?
      approved_team_id = nil

      player.licenses.map! do |lic|
        if lic['id'] == params[:license_id]
          last_status = lic['history'].sort_by { |h| h['created_at'] }.last

          if last_status['license_status_id'].to_i != params[:license_status_id].to_i &&
             ([License::APPROVED, License::DENIED].include?(params[:license_status_id].to_i) ||
              ([License::TRANSFER].include?(params[:license_status_id].to_i) && current_user.special_user)
             )
            lic['history'] << {
              license_status_id: params[:license_status_id].to_i,
              reason: params[:reason] || '',
              created_by: current_user.id,
              created_at: Time.now
            }
            approved_team_id = lic['team_id'] if params[:license_status_id].to_i == License::APPROVED
          end
        end

        lic
      end

      if player.save
        if approved_team_id && player.email.present?
          team = Team.find_by(id: approved_team_id)
          PlayerMailer.license_approved(player, team).deliver_later if team
        end
        render json: { success: true }
      else
        render json: { message: player.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def handle_license_doublication
    if current_user && %w[jho_admin buettner_sbk mguenther].include?(current_user.user_name)
      player = Player.find(params[:id])
      player.fix_player_licenses!

      render json: { success: true }
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def admin_licenses
    # hole spieler
    league = League.find(params[:id])

    ph = current_user.permission_hash

    if ph[:admin].present? || ph[:sbk].present?
      render json: league.licenses(true)
    else
      render json: { message: 'Keine Berechtigung!' }, status: :forbidden
    end
  end

  def user_licenses_temp
    # hole spieler
    league = League.find(params[:id])

    ph = current_user.permission_hash

    # get playing clubs, including sg
    teams = league.teams
    club_ids = teams.map(&:all_club_ids).flatten.compact.uniq
    # get hosting clubs
    all_club_ids = [club_ids, league.game_days.map(&:club_id)].flatten.compact.uniq

    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                # vm: permission for one of those clubs?
                ph[:vm].intersection(all_club_ids).present?
              elsif ph[:tm].present?
                # tm: get clubs for league teams of given team, permission for one of those?
                ph[:tm].intersection(teams.map(&:id)).present?
              end

    if allowed
      render json: league.licenses(true)
    else
      render json: { message: 'Keine Berechtigung!' }, status: :forbidden
    end
  end

  def withdraw_license_request
    player = Player.find(params[:id])

    player.licenses.each { |l| l['id'] ||= l.delete('_id') }
    found_license = player.licenses.find { |l| l['id'] == params[:license_id] }
    return render json: { message: 'Lizenz nicht gefunden.' }, status: :not_found unless found_license

    team = Team.find(found_license['team_id'])
    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].include?(team.club_id) || ph[:vm].intersection(team.syndicate_clubs).present?
              elsif ph[:tm].present?
                ph[:tm].include?(team.id)
              end
    return render json: { message: 'Keine Berechtigung für dieses Team!' }, status: :forbidden unless allowed

    last_status_id = found_license['history'].max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
    unless last_status_id == License::REQUESTED
      return render json: { message: 'Nur beantragte Lizenzen können zurückgezogen werden.' },
                    status: :unprocessable_entity
    end

    last_requested = found_license['history']
                       .select { |h| h['license_status_id'].to_i == License::REQUESTED }
                       .max_by { |h| h['created_at'] }

    if last_requested && (Time.now - last_requested['created_at'].to_time) < 24.hours
      player.licenses.reject! { |l| l['id'] == params[:license_id] }
      if player.save
        render json: { success: true, grace_period_deletion: true }
      else
        render json: { message: player.errors }, status: :unprocessable_entity
      end
    else
      meta_user_license_change(License::WITHDRAWN)
    end
  end

  def reenable_license_request
    meta_user_license_change(License::REQUESTED)
  end

  def meta_user_license_change(status)
    # hole spieler
    player = Player.find(params[:id])

    found_license = nil
    player.licenses.map! do |license|
      if license['_id'].present?
        license['id'] = license['_id']
        license['_id'] = nil
      end
      if license['id'] == params[:license_id]
        found_license = license

        license['history'] << {
          license_status_id: status,
          created_by: current_user.id,
          created_at: Time.now
        }
      end

      license
    end

    # prüfe ob user lizenz für team beantragen darf
    team = Team.find(found_license['team_id'])

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].include?(team.club_id) || ph[:vm].intersection(team.syndicate_clubs).present?
              elsif ph[:tm].present?
                ph[:tm].include?(team.id)
              end

    if allowed
      if player.save
        render json: { success: true }
      else
        render json: { message: player.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung für dieses Team!' }, status: :forbidden
    end
  end

  def admin_player_update
    if current_user
      create_modus = params[:id].zero?
      # check: game operation permission if create_modus
      #   has: create team for that go?
      #   else : unpermitted!
      # check: league permission unless create_modus
      #   has: update league for that league?
      #   else : unpermitted!
      if create_modus && Club.find(params[:club_id])&.user_permissions(current_user)&.include?(:create_player) # create

        first_name = "%#{params['first_name'].downcase.strip}%"
        last_name = "%#{params['last_name'].downcase.strip}%"
        birthdate = params['birthdate'].to_date
        existing_player_id = Player.where('first_name ILIKE ? AND last_name ILIKE ? AND birthdate = ?', first_name,
                                          last_name, birthdate).limit(1).pluck(:id).first

        if existing_player_id.present?
          render json: { message: "Es existiert ein Spieler mit diesen Daten (ID: #{existing_player_id}). Anlegen nicht möglich." },
                 status: :unprocessable_entity
        else
          pp = player_params
          player = Player.new(pp)
          player.clubs = [{
            club_id: params[:club_id].to_i,
            home_club: true,
            created_at: Time.now,
            created_by: current_user.id
          }]
          player.created_by = current_user.id

          player.save

          render json: player, status: :created
        end
      elsif !create_modus && Club.find(params[:club_id])&.user_permissions(current_user)&.include?(:update_player) # update
        # update
        player = Player.find(params[:id])
        player.updated_by = current_user.id
        if player.update(player_params)
          render json: player
        else
          render json: player.errors, status: :unprocessable_entity
        end
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def add_additional_club
    # hole spieler
    player = Player.find(params[:id])
    club = Club.find(params[:club_id])

    ph = current_user.permission_hash

    if ph[:admin].present? || ph[:sbk].present?

      # if player and club present, we check if the club.id is already in the players clubs hash
      if player.present? &&
         club.present?

        if !player.clubs.select do |c|
              c['valid_until'].nil? || c['valid_until'].to_date > Date.today
            end.map do |c|
             c['club_id']
           end.include?(club.id)
          # valid until next 15.07.20XX
          valid_until = Date.new(Date.today.year, 7, 15).to_time
          valid_until += 1.year if valid_until < Time.now

          club_entry = {
            club_id: club.id,
            home_club: false,
            created_by: current_user.id,
            valid_set_by: current_user.id,
            created_at: Time.now,
            valid_until:
          }
          # add club to clubs array
          player.clubs << club_entry

          if player.save
            render json: { success: true }
          else
            render json: { message: player.errors }, status: :unprocessable_entity
          end
        else
          render json: { message: 'Spieler bereits in dem Verein vorhanden' }, status: :unprocessable_entity
        end
      else
        render json: { message: 'Verein oder Spieler nicht gefunden' }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def remove_additional_club
    # hole spieler
    player = Player.find(params[:id])
    club = Club.find(params[:club_id])

    ph = current_user.permission_hash

    if ph[:admin].present? || ph[:sbk].present?

      # if player and club present, we check if the club.id is already in the players clubs hash
      if player.present? &&
         club.present?

        player.clubs.map! do |c|
          # additional club == ! home
          # entry only for given club
          # valid_until should always be present in this case, check to avoid errors and only check for current entries
          if !c['home_club'] &&
             c['club_id'] == club.id &&
             c['valid_until'].present? && c['valid_until'].to_time > Time.now && c['valid_until'] == params[:valid_until]
            c['valid_until'] = Time.now
            c['valid_set_by'] = current_user.id
          end

          c
        end

        if player.save
          render json: { success: true }
        else
          render json: { message: player.errors }, status: :unprocessable_entity
        end
      else
        render json: { message: 'Verein oder Spieler nicht gefunden' }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def transfer
    # hole spieler
    player = Player.find(params[:id])
    club = Club.find(params[:club_id])

    ph = current_user.permission_hash

    if ph[:admin].present? || ph[:sbk].present?

      # if player and club present, we check if the club.id is already in the players clubs hash
      if player.present? &&
         club.present?

        if !player.clubs.select do |c|
              c['valid_until'].nil? || c['valid_until'].to_date > Date.today
            end.map do |c|
             c['club_id']
           end.include?(club.id)

          current_teams = club.current_teams
          current_licenses = (player.current_licenses || []).reject do |l|
                               [6, 7].include?(l['history'].last['license_status_id'].to_i)
                             end.map { |l| l['team_id'] }

          # check for licenses for that club
          if current_licenses.empty?

            old_club_id = nil

            player.clubs.map! do |c|
              # if it's a current entry for the home_club
              if c['valid_until'].nil? && c['home_club']
                c['valid_until'] = Time.now
                c['valid_set_by'] = current_user.id

                old_club_id = c['club_id']
              end

              c
            end

            new_club_entry = {
              club_id: club.id,
              home_club: true,
              created_by: current_user.id,
              created_at: Time.now
            }

            # add club to clubs array
            player.clubs << new_club_entry

            if old_club_id.present?
              transfer = Transfer.new({
                                        created_by: current_user.id,
                                        former_club_id: old_club_id,
                                        new_club_id: club.id,
                                        player_id: player.id,
                                        season_id: Setting.current_season_id
                                      })

              success = false

              Player.transaction do
                transfer.save!
                player.save!

                success = true
              end

              if success
                render json: { success: true }
              else
                render json: { message: player.errors }, status: :unprocessable_entity
              end
            else
              render json: { message: 'Konnte alten Verein nicht finden. Abbruch.' },
                     status: :unprocessable_entity
            end
          else
            render json: { message: "Spieler hat für diesen Verein eine Lizenz (Team: #{current_licenses.join ','})" },
                   status: :unprocessable_entity
          end

        else
          render json: { message: 'Spieler bereits in dem Verein vorhanden' }, status: :unprocessable_entity
        end
      else
        render json: { message: 'Verein oder Spieler nicht gefunden' }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def stats
    player = Player.find(params[:id])
    setting = Setting.current
    seasons_map = setting.seasons.each_with_object({}) { |(k, v), h| h[k.to_i] = v['name'] }

    # Find all ended games where this player was in the lineup
    player_id = player.id
    games = Game
            .joins(game_day: { league: :game_operation })
            .where(ended: true)
            .where(
              "players->'home' @> ? OR players->'guest' @> ?",
              "[{\"player_id\":#{player_id}}]",
              "[{\"player_id\":#{player_id}}]"
            )
            .includes(game_day: { league: :game_operation })

    # season_id → league_id → aggregated stats
    by_season = {}

    games.each do |game|
      scorer_data = game.evaluate_scorer[player_id]
      next if scorer_data.nil?

      league      = game.game_day.league
      season_id   = league.season_id.to_i
      league_id   = league.id

      by_season[season_id] ||= {}
      entry = by_season[season_id][league_id] ||= {
        league_id:,
        league_name:    league.name,
        league_slug:    "#{league.id}-#{league.short_name&.parameterize}",
        game_operation: league.game_operation.short_name,
        team_id:        scorer_data[:team_id],
        team_name:      scorer_data[:team_name],
        games: 0, goals: 0, assists: 0, penalty_minutes: 0
      }

      entry[:games]           += 1
      entry[:goals]           += scorer_data[:goals]
      entry[:assists]         += scorer_data[:assists]
      entry[:penalty_minutes] += (scorer_data[:penalty_2]      * 2) +
                                 (scorer_data[:penalty_2and2]   * 4) +
                                 (scorer_data[:penalty_5]       * 5) +
                                 (scorer_data[:penalty_10]      * 10) +
                                 (scorer_data[:penalty_ms_tech] + scorer_data[:penalty_ms_full] +
                                  scorer_data[:penalty_ms1]     + scorer_data[:penalty_ms2] +
                                  scorer_data[:penalty_ms3]) * 25
    end

    seasons = by_season
              .sort_by { |season_id, _| -season_id }
              .map do |season_id, leagues|
      league_entries = leagues.values.sort_by { |e| -e[:games] }
      {
        season_id:,
        season_name: seasons_map[season_id] || season_id.to_s,
        leagues:     league_entries
      }
    end

    total_games   = seasons.sum { |s| s[:leagues].sum { |l| l[:games] } }
    total_goals   = seasons.sum { |s| s[:leagues].sum { |l| l[:goals] } }
    total_assists = seasons.sum { |s| s[:leagues].sum { |l| l[:assists] } }
    last_season   = seasons.first

    render json: {
      player: {
        id:         player.id,
        first_name: player.first_name,
        last_name:  player.last_name,
        birthdate:  player.birthdate,
        gender:     player.gender
      },
      seasons:,
      totals: {
        games:          total_games,
        goals:          total_goals,
        assists:        total_assists,
        scorer_points:  total_goals + total_assists,
        scorer_per_game: total_games > 0 ? ((total_goals + total_assists).to_f / total_games).round(2) : 0,
        last_season:    last_season&.dig(:season_name)
      }
    }
  end

  def transfers_public
    result = Rails.cache.fetch('transfers', expires_in: 30.minutes) do
      Transfer.includes(:former_club, :new_club, :player).where(season_id: Setting.current_season_id).map(&:as_json)
    end

    render json: result
  end

  private

  def set_player
    @player = Player.find(params[:id])
  end

  def player_params
    params.require(:player).permit(:birthdate, :first_name, :last_name, :male, :gender, :nation_id, :email)
  end
end
