class ClubsController < ApplicationController
  # GET /clubs
  def index
    @clubs = Clubs.all

    render json: @clubs
  end

  def user_clubs_and_teams
    ph = current_user.permission_hash
    clubs = if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
              Club.all
            elsif ph[:admin].present? || ph[:sbk].present?
              go_ids = []
              go_ids << ph[:admin] if ph[:admin].present?
              go_ids << ph[:sbk] if ph[:sbk].present?

              GameOperation.find(go_ids).map(&:clubs).flatten.uniq
            elsif ph[:vm].present?
              Club.where(id: ph[:vm])
            elsif ph[:tm].present?
              teams = Team.current_season.where(id: ph[:tm])
              teams.map(&:all_clubs).flatten.uniq
            end

    result = []

    clubs.each do |club|
      item = club.full_hash
      teams = if ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?
                club.current_teams
              elsif ph[:tm].present?
                club.current_teams.select { |team| ph[:tm].include?(team.id) }
              else
                []
              end
      item[:teams] = teams.map(&:full_hash)
      result << item
    end

    render json: result
  end

  def user_team_licenses
    ph = current_user.permission_hash

    team = Team.find(params[:id])

    # get leagues for team
    leagues = team.leagues
    # get playing clubs, including sg
    teams = leagues.map(&:teams).flatten.compact.uniq
    club_ids = teams.map(&:all_club_ids).flatten.compact.uniq
    # get hosting clubs
    all_club_ids = [club_ids, leagues.map { |l| l.game_days.map(&:club_id) }].flatten.compact.uniq

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
      result = {}

      result[:team] = team.full_hash

      clubs = Club.find(team.all_club_ids)
      all_players = clubs.map(&:players).flatten.compact

      result[:current_requests] = []
      result[:other_players] = []

      all_players.each do |p|
        l = p.licenses_by_team(team.id)
        if l.present?
          item = p.full_hash
          item[:team_license] = l
          cs = p.current_license_status(l)
          item[:current_status] = cs
          item[:can_withdraw] = (cs['license_status_id'] == License::REQUESTED)
          result[:current_requests] << item
        else
          result[:other_players] << p.meta_hash
        end
      end

      render json: result
    else
      render json: { success: false }, status: :forbidden
    end
  end

  def self.admin_user_players(user, club_id)
    club_object = Club.find(club_id)

    # wenn admin oder sbk global: füge alle hinzu
    ph = user.permission_hash
    club = if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
             club_object
           elsif ph[:admin].present? || ph[:sbk].present?
             go_ids = []
             go_ids << ph[:admin] if ph[:admin].present?
             go_ids << ph[:sbk] if ph[:sbk].present?

             # if club and permission share a go_id we are allowed to see this
             club_object if go_ids.flatten.intersection(club_object.game_operations_hash.map do |go|
                                                          go['game_operation_id']
                                                        end).present?
           elsif ph[:vm].present?
             club_object if ph[:vm].include?(club_id)
           end

    return unless club

    result = club.full_hash
    result[:players] = club.players.map(&:meta_hash)

    # this was the all club index code:
    # clubs = []

    # GameOperation.find(go_ids).each do |go|
    #   clubs << go.clubs
    # end

    # clubs << Club.find(ph[:vm]) if ph[:vm]&.present?

    # clubs = clubs.flatten.uniq

    # clubs.each do |c|
    #   item = c.full_hash
    #   item[:players] = c.players
    #   result << item
    # end

    result
  end

  def admin_get_go_clubs
    if current_user
      league = if params[:callType] == 'l'
                 League.find(params[:id])
               else
                 team = Team.find(params[:id])
                 team&.league
               end

      game_operation = league&.game_operation
      if game_operation && game_operation&.user_permissions(current_user)&.include?(:index_clubs)
        render json: game_operation.clubs.map(&:full_hash)
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_club_all
    result = Club.all

    render json: result
  end

  def admin_club_index
    if current_user
      result = Club.admin_user_clubs(current_user)

      render json: result
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_club
    if current_user
      result = Club.find(params[:id])

      render json: result.full_hash
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_club_update
    if current_user
      create_modus = params[:id].zero?
      # check: game operation permission if create_modus
      #   has: create club for that go?
      #   else : unpermitted!
      # check: club permission unless create_modus
      #   has: update club for that club?
      #   else : unpermitted!
      if create_modus && GameOperation.find(params[:game_operation_id])&.user_permissions(current_user)&.include?(:create_club) # create

        cp = club_params
        cp[:game_operations_hash] = [{ home_game_operation: true, game_operation_id: params[:game_operation_id] }]
        cp[:created_by] = current_user.id
        cp[:updated_by] = current_user.id
        club = Club.create(cp)

        render json: club, status: :created
      elsif !create_modus && Club.find(params[:id])&.user_permissions(current_user)&.include?(:update_club) # update
        # update
        club = Club.find(params[:id])
        club.updated_by = current_user.id

        if params[:game_operation_id].present?
          new_go_id = params[:game_operation_id].to_i
          others = (club.game_operations_hash || []).reject { |h| h['home_game_operation'] }
          club.game_operations_hash = others + [{ 'home_game_operation' => true, 'game_operation_id' => new_go_id }]
        end

        if club.update(club_params)
          render json: club.full_hash
        else
          render json: club.errors, status: :unprocessable_entity
        end
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_upload_logo
    if current_user
      club = Club.find(params[:id])

      unless club.user_permissions(current_user).include?(:update_club)
        return render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

      unless params[:logo].present?
        return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity
      end

      club.logo.attach(params[:logo])
      render json: { logo_url: club.logo_url, logo_small_url: club.logo_small_url }
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def club_params
    params.require(:club).permit(:name, :short_name, :long_name, :state)
  end
end
