class PlayersController < ApplicationController
  before_action :set_player, only: %i[show update destroy]

  # GET /players
  def index
    @players = Player.all.order(:last_name).order(:first_name).where("last_name != '' AND first_name != ''").order(:birthdate)
  end

  # GET /players/1
  def show; end

  def admin_players_index
    if current_user
      result = Player.admin_user_players(current_user, params[:club_id])

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

  def admin_player
    if current_user
      result = Player.find(params[:id])

      render json: result.full_hash
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def request_license
    # hole spieler
    player = Player.find(params[:id])
    team = Team.find(params[:team_id])
    league = team.league

    ph = current_user.permission_hash
    # prüfe ob user lizenz für team beantragen darf
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].include?(team.club_id) || ph[:vm].intersection(team.syndicate_clubs).present?
              elsif ph[:tm].present?
                ph[:tm].include?(team.id)
              end

    # TODO:
    # prüfe ob eine lizenz für das team bereits vorliegt

    if allowed
      # füge lizenz zu lizenzhash hinzu
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

      if player.save
        render json: { success: true }
      else
        render json: { message: player.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung für dieses Team!' }, status: :forbidden
    end
  end

  def withdraw_license_request
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
          license_status_id: License::WITHDRAWN,
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
            club_id: params[:club_id],
            home_club: true,
            created_at: Time.now,
            created_by: current_user.ids
          }]
          player.created_by = current_user.ids

          player.save

          render json: player, status: :created
        end
      elsif !create_modus && Club.find(params[:club_id])&.user_permissions(current_user)&.include?(:update_player) # update
        # update
        player = Player.find(params[:id])
        player.updated_by = current_user.ids
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
          valid_until = Date.new(Date.today.year, 7, 15)
          valid_until += 1.year if valid_until < Date.today

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
          current_licenses = player.current_licenses_meta(current_teams).map { |l| l['team_id'] }
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

  private

  def set_player
    @player = Player.find(params[:id])
  end

  def player_params
    params.require(:player).permit(:birthdate, :first_name, :last_name, :male, :nation_id)
  end
end
