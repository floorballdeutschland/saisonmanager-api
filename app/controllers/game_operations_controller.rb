class GameOperationsController < ApplicationController
  before_action :set_game_operation, only: %i[index_leagues index_clubs admin_upload_banner admin_delete_banner admin_update_banner_link]
  skip_before_action :authenticate_user, except: %i[admin_game_operations admin_upload_banner admin_delete_banner admin_update_banner_link]
  before_action :authenticate_public_request, except: %i[admin_game_operations admin_upload_banner admin_delete_banner admin_update_banner_link]

  # GET /game_operations
  def index
    @game_operations = GameOperation.all.order(:id)

    expires_in 60.seconds, public: true
    render json: @game_operations
  end

  # GET /game_operations/1/leagues
  def index_leagues
    current_season_id = Setting.current_season_id

    leagues = @game_operation.leagues
    leagues = if params[:season_id]
                leagues.where(season_id: params[:season_id])
              else
                leagues.where(season_id: current_season_id)
              end

    render json: leagues.with_full_hash_includes.map(&:full_hash)
  end

  # GET /game_operations/1/clubs/:season_id
  # Vereine eines Spielbetriebs samt der Teams, die in der angegebenen Saison
  # (Default: aktuelle Saison) im Einsatz sind. Vereine werden aus den tatsächlich
  # gemeldeten Teams abgeleitet (inkl. Spielgemeinschafts-Vereinen über syndicate_clubs),
  # nicht aus der reinen Vereinsregistrierung. Öffentlich (X-Api-Key) – ohne contact_email.
  def index_clubs
    season_id = params[:season_id].presence || Setting.current_season_id

    league_ids = @game_operation.leagues.where(season_id:).select(:id)
    teams = Team.where(league_id: league_ids)
                .includes(:club, logo_attachment: :blob, league: :game_operation)

    teams_by_club_id = Hash.new { |h, k| h[k] = [] }
    teams.each { |team| team.all_club_ids.each { |cid| teams_by_club_id[cid] << team } }

    clubs = Club.where(id: teams_by_club_id.keys)
                .includes(logo_attachment: :blob)
                .order(:name)

    result = clubs.map do |club|
      item = club.public_hash
      item[:teams] = teams_by_club_id[club.id].sort_by(&:name).map(&:full_hash)
      item
    end

    render json: result
  end

  # GET /game_operations/by_shortname/:name
  def by_shortname
    @game_operation = GameOperation.find_by path: params[:name]
    render json: @game_operation
  end

  def admin_game_operations
    go_ids = []

    ph = current_user.permission_hash
    if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
      go_ids = GameOperation.all.pluck(:id)
    elsif ph[:admin].present? || ph[:sbk].present?
      go_ids << ph[:admin] if ph[:admin].present?
      go_ids << ph[:sbk] if ph[:sbk].present?
      go_ids.flatten!
    elsif ph[:vm].present?
      go_ids = Club.where(id: ph[:vm])
                   .flat_map { |c| [c.main_game_operation_id, *c.additional_game_operation_ids] }
                   .compact.uniq
    end

    render json: GameOperation.where(id: go_ids).order(:id)
  end

  def admin_upload_banner
    return render json: { message: 'Keine Berechtigung' }, status: :forbidden unless admin?

    return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity unless params[:banner].present?

    unless params[:banner].content_type == 'image/webp'
      return render json: { message: 'Nur WebP-Dateien erlaubt' }, status: :unprocessable_entity
    end

    if params[:banner].size > 500.kilobytes
      return render json: { message: 'Maximale Dateigröße: 500 KB' }, status: :unprocessable_entity
    end

    begin
      @game_operation.banner.attach(params[:banner])
      @game_operation.update!(banner_link_url: params[:banner_link_url].presence)
      render json: { banner_url: @game_operation.banner_url, banner_link_url: @game_operation.banner_link_url }
    rescue StandardError => e
      Rails.logger.error("Banner-Upload fehlgeschlagen (GameOperation #{@game_operation.id}): #{e.class}: #{e.message}")
      render json: { message: 'Banner konnte nicht gespeichert werden.' }, status: :internal_server_error
    end
  end

  def admin_delete_banner
    return render json: { message: 'Keine Berechtigung' }, status: :forbidden unless admin?

    begin
      @game_operation.banner.purge
      render json: { success: true }
    rescue StandardError => e
      Rails.logger.error("Banner-Löschen fehlgeschlagen (GameOperation #{@game_operation.id}): #{e.class}: #{e.message}")
      render json: { message: 'Banner konnte nicht gelöscht werden.' }, status: :internal_server_error
    end
  end

  def admin_update_banner_link
    return render json: { message: 'Keine Berechtigung' }, status: :forbidden unless admin?

    @game_operation.update!(banner_link_url: params[:banner_link_url].presence)
    render json: { banner_link_url: @game_operation.banner_link_url }
  rescue ActiveRecord::RecordInvalid => e
    render json: { message: e.message }, status: :unprocessable_entity
  end

  private

  # Banner-Verwaltung: globaler Admin (0) oder Admin des konkreten Spielbetriebs.
  def admin?
    admin_go_ids = current_user.permission_hash[:admin].to_a
    admin_go_ids.include?(0) || admin_go_ids.include?(@game_operation.id)
  end

  def set_game_operation
    @game_operation = GameOperation.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { message: 'Spielbetrieb nicht gefunden' }, status: :not_found
  end
end
