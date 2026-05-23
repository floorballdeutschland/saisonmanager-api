class LeaguesController < ApplicationController
  skip_before_action :authenticate_user, except: %i[admin_league_index admin_upload_banner admin_delete_banner]
  before_action :authenticate_public_request, except: %i[admin_league_index admin_upload_banner admin_delete_banner]
  after_action :track_public_view, only: %i[schedule current_schedule game_day_schedule table grouped_table scorer]

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
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_league_team_index
    if current_user
      league = League.find(params[:id])

      if league
        render json: league.hash_with_teams
      else
        render json: { message: 'Keine passende Liga gefunden.' }, status: :not_found
      end
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_league_permissions
    if current_user
      result = League.admin_league_permissions(current_user)

      render json: result
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
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
        if BUNDESLIGA_CLASSES.include?(lp[:league_class_id]) && !buli_permitted?(current_user)
          return render json: { message: 'Keine Berechtigung für diese Ligaklasse' }, status: :forbidden
        end

        lp[:season_id] = Setting.current_season_id
        lp[:legacy_league] = false
        league = League.create(lp)

        render json: league, status: :created
      elsif !create_modus && League.find(params[:id])&.user_permissions(current_user)&.include?(:update_league) # update
        league = League.find(params[:id])
        lp = league_params
        effective_class = lp[:league_class_id] || league.league_class_id
        if BUNDESLIGA_CLASSES.include?(effective_class) && !buli_permitted?(current_user)
          return render json: { message: 'Keine Berechtigung für diese Ligaklasse' }, status: :forbidden
        end

        if league.update(lp)
          render json: league
        else
          render json: league.errors, status: :unprocessable_entity
        end
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_league_classes
    if current_user
      render json: Setting.current.league_classes.map { |k, v|
                     v['id'] = k
                     v
                   }
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_game_schedule
    if current_user
      league = League.find(params[:id])

      if league
        items = league.game_days.includes(:arena, :club, :games).map do |gd|
                  gd.full_hash(true)
                end.sort_by do |gd|
                  first_game_number = gd[:games].present? ? gd[:games].first[:number].to_i : 0
                  [gd[:number].to_i, gd[:date], first_game_number]
                end
        render json: items
      else
        render json: { message: 'Keine passende Liga gefunden.' }, status: :not_found
      end
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_schedule_import_template
    if current_user
      @league = League.find(params[:id])

      if @league
        if @league.user_permissions(current_user)&.include?(:download_template)
          @arenas = Arena.active.order(:city, :name)
          @teams = @league.teams
          @clubs = @teams.map(&:all_clubs).flatten.uniq

          render xlsx: 'admin_schedule_import_template', filename: "import_template_#{@league.id}.xlsx"
        else
          render json: { message: 'Kein Zugriff' }, status: :forbidden
        end

      else
        render json: { message: 'Keine passende Liga gefunden.' }, status: :not_found
      end
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_schedule_import_games
    if current_user && params[:file].present?

      creek = Creek::Book.new params[:file], with_headers: false
      sheet = creek.sheets[0]

      errors = []
      warnings = []

      user_id = current_user.id

      if sheet.name == 'Import'
        league = League.find(sheet.simple_rows.to_a[1]['A'])
        if league

          if league.user_permissions(current_user)&.include?(:import_games)

            errors << 'Liga hat bereits Spiele und/oder Spieltage' if league.games.present? || league.game_days.present?

            arena_ids = Arena.active.pluck(:id)
            teams = league.teams
            team_ids = teams.map(&:id)
            club_ids = teams.map(&:all_club_ids).flatten.compact.uniq

            game_days = {}
            games = {}
            used_game_numbers = []

            sheet.simple_rows.each_with_index do |row, i|
              next if i < 9
              break if row['A'].blank? || errors.present?

              game_days[row['C'].to_i] ||= {}
              games[row['C'].to_i] ||= []

              home_team_id = if row['H'].present? && team_ids.include?(row['H'].to_i)
                               row['H'].to_i
                             else
                               errors << "Zeile #{i + 1}: Heimteam nicht erkannt"
                               nil
                             end

              guest_team_id = if row['I'].present? && team_ids.include?(row['I'].to_i)
                                row['I'].to_i
                              else
                                errors << "Zeile #{i + 1}: Gastteam nicht erkannt"
                                nil
                              end

              game_number = if row['B'].present? && !used_game_numbers.include?(row['B'].to_i)
                              number = row['B'].to_i
                              used_game_numbers << number

                              number
                            else
                              errors << "Zeile #{i + 1}: Spielnummer nicht erkannt, oder doppelt verwendet"
                              nil
                            end

              parsed_start_time = if row['E'].instance_of?(Time)
                                    row['E'].strftime('%H:%M')
                                  elsif row['E'].instance_of?(String) && /^[0-2]\d{1}:\d{2}$/.match(row['E'])
                                    row['E']
                                  elsif row['E'].instance_of?(String) && /^[0-2]\d{1}:\d{2}:\d{2}$/.match(row['E'])
                                    row['E'][0..4]
                                  else
                                    errors << "Zeile #{i + 1}: Startzeit nicht erkannt, falsches Format?"
                                    nil
                                  end

              games[row['C'].to_i] << {
                home_team_id:,
                game_number:,
                guest_team_id:,
                start_time: parsed_start_time,
                nominated_referee_string: row['J'].present? ? row['J'] : '',
                created_by: user_id
              }

              next if game_days[row['C'].to_i].present?

              parsed_date = if row['D'].instance_of?(Date)
                              row['D'].to_s
                            elsif row['D'].instance_of?(Time)
                              row['D'].to_date.to_s
                            elsif row['D'].instance_of?(String)
                              begin
                                Date.parse(row['D']).to_s
                              rescue Date::Error => e
                                errors << "Zeile #{i + 1}: Fehlerhaftes Datum #{row['D'].class}, #{row['D']}"
                              end
                            else
                              errors << "Zeile #{i + 1}: Datum nicht erkannt #{row['D'].class}, #{row['D']}"
                              nil
                            end

              arena_id = if row['F'].present?
                           if arena_ids.include?(row['F'].to_i)
                             row['F'].to_i
                           else
                             errors << "Zeile #{i + 1}: Halle nicht erkannt"
                             nil
                           end
                         else
                           warnings << "Zeile #{i + 1}: Keine Halle hinterlegt"
                           nil
                         end

              club_id = if row['G'].present?
                          if club_ids.include?(row['G'].to_i)
                            row['G'].to_i
                          else
                            errors << "Zeile #{i + 1}: Ausrichter nicht erkannt"
                            nil
                          end
                        else
                          warnings << "Zeile #{i + 1}: Kein Ausrichter hinterlegt"
                          nil
                        end

              game_day_number = if row['A'].present?
                                  row['A'].to_i
                                else
                                  errors << "Zeile #{i + 1}: Spieltagsnummer nicht erkannt"
                                  nil
                                end

              game_days[row['C'].to_i] = {
                date: parsed_date,
                number: game_day_number,
                league_id: league.id,
                arena_id:,
                club_id:,
                created_by: user_id
              }

              # test
            end
          else
            errors << 'fehlende Berechtigung'
          end
        else
          errors << 'Liga konnte nicht gefunden werden, Abbruch.'
        end
      else
        errors << 'Datei ungütig, Vorlage verwenden!'
      end

      if errors.present?
        render json: { message: { errors:, warnings: }.to_json },
               status: :bad_request
      else
        ActiveRecord::Base.transaction do
          # erzeuge spieltage
          game_days.each do |k, v|
            gd = GameDay.create(v)

            game_days[k][:gd] = gd
          end

          # erzeuge Spiele
          games.map do |k, v|
            gd_id = game_days[k][:gd].id
            v.map do |game_hash|
              game_hash[:game_day_id] = gd_id
              game_hash[:started] = false
              game_hash[:ended] = false
              game_hash[:game_ended] = false
              Game.create(game_hash)
            end
          end
        end

        render json: { errors:, warnings: }
      end
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def copy_preround_licenses
    return render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized unless current_user

    league = League.find(params[:id])

    unless league.user_permissions(current_user).include?(:update_league)
      return render json: { message: 'Keine Berechtigung!' }, status: :forbidden
    end

    preround_league_id = league.league_id_preround
    unless preround_league_id.present?
      return render json: { message: 'Keine Vorrunden-Liga konfiguriert.' }, status: :unprocessable_entity
    end

    preround_league = League.find_by(id: preround_league_id)
    unless preround_league
      return render json: { message: 'Vorrunden-Liga nicht gefunden.' }, status: :not_found
    end

    current_team_by_club = league.teams.index_by(&:club_id)
    preround_team_by_club = preround_league.teams.index_by(&:club_id)

    copied_count = 0

    ActiveRecord::Base.transaction do
      current_team_by_club.each do |club_id, current_team|
        preround_team = preround_team_by_club[club_id]
        next unless preround_team

        preround_players = Player.find_by_team_id(preround_team.id).uniq(&:id)

        preround_players.each do |player|
          preround_license = (player.licenses || []).find do |l|
            l['team_id'].to_i == preround_team.id &&
              l['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i == License::APPROVED
          end
          next unless preround_license
          next if (player.licenses || []).any? { |l| l['team_id'].to_i == current_team.id }

          fresh_player = Player.find(player.id)
          new_license = {
            'id' => SecureRandom.uuid,
            'team_id' => current_team.id,
            'history' => [{
              'license_status_id' => License::APPROVED,
              'created_at' => Time.current.iso8601
            }]
          }
          fresh_player.licenses = (fresh_player.licenses || []) + [new_license]
          copied_count += 1 if fresh_player.save
        end
      end
    end

    render json: { copied: copied_count }
  end

  def user_leagues_license_list_index
    if current_user
      result = League.user_leagues_license_list(current_user)

      render json: result
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  # GET /leagues/1
  def show
    league = League.find(params[:id])

    respond_to do |format|
      format.json { render json: league.full_hash(true) }
      format.ics do
        ical = ::Icalendar::Calendar.new

        events = league.games.map(&:ical)
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

  # GET /leagues/1/schedule
  api :GET, '/leagues/:id/schedule.json'
  param :id, :number,
        required: true, desc: 'league id'
  # short_description 'Prints the game schedule for league :id.'
  description <<-EOS
      Prints the game schedule for league :id. If the game was already played a result_string is included.
  EOS
  def schedule
    id = params[:id]

    schedule = Rails.cache.fetch("leagues/#{id}/schedule", expires_in: 5.minutes) do
      @league = League.find(id)

      @league.schedule
    end

    render json: schedule
  end

  # GET /leagues/1/game_days/15/schedule
  def game_day_schedule
    @league = League.find(params[:id])

    render json: @league.game_day_schedule(params[:game_day_number])
  end

  # GET /leagues/1/game_days/current/schedule
  def current_schedule
    id = params[:id]

    current_schedule = Rails.cache.fetch("leagues/#{id}/current_schedule", expires_in: 5.minutes) do
      @league = League.find(id)

      @league.current_schedule
    end

    render json: current_schedule
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

  def grouped_table
    @league = League.find(params[:id])

    render json: @league.grouped_table
  end

  def license_list
    league = League.find(params[:id])

    hash = league.short_hash true

    render json: hash
  end

  def meta
    @league = League.find(params[:id])

    render json: @league.meta_item
  end

  def additional_references
    league = League.find(params[:id])
    teams = league.teams

    render json: {
      arenas: Arena.active.order(:city, :name).sort_by { |a| a.city.present? ? 0 : 1 }.map(&:full_hash),
      teams: league.teams.map(&:full_hash),
      clubs: teams.map(&:all_clubs).flatten.uniq.map(&:full_hash)
    }
  end

  def penalties
    penalties = Setting.current.penalties.reject do |_k, v|
                  v['disabled'].present?
                end.map do |k, v|
                  v['id'] = k
                  v
                end.sort_by { |i| i['order'] }

    render json: penalties
  end

  def penalty_codes
    penalty_codes = Setting.current.penalty_codes.select { |_k, v| v['active'].present? }.map do |k, v|
      v['id'] = k
      v
    end

    render json: penalty_codes
  end

  def admin_upload_banner
    league = find_league_or_not_found or return
    unless league.user_permissions(current_user).include?(:update_league)
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity unless params[:banner].present?

    unless params[:banner].content_type == 'image/webp'
      return render json: { message: 'Nur WebP-Dateien erlaubt' }, status: :unprocessable_entity
    end

    if params[:banner].size > 500.kilobytes
      return render json: { message: 'Maximale Dateigröße: 500 KB' }, status: :unprocessable_entity
    end

    begin
      league.banner.attach(params[:banner])
      render json: { banner_url: league.banner_url }
    rescue StandardError => e
      Rails.logger.error("Banner-Upload fehlgeschlagen (League #{league.id}): #{e.class}: #{e.message}")
      render json: { message: 'Banner konnte nicht gespeichert werden.' }, status: :internal_server_error
    end
  end

  def admin_delete_banner
    league = find_league_or_not_found or return
    unless league.user_permissions(current_user).include?(:update_league)
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    begin
      league.banner.purge
      render json: { success: true }
    rescue StandardError => e
      Rails.logger.error("Banner-Löschen fehlgeschlagen (League #{league.id}): #{e.class}: #{e.message}")
      render json: { message: 'Banner konnte nicht gelöscht werden.' }, status: :internal_server_error
    end
  end

  def find_league_or_not_found
    League.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { message: 'Liga nicht gefunden' }, status: :not_found
    nil
  end
  private :find_league_or_not_found

  BUNDESLIGA_CLASSES = %w[1fbl 2fbl].freeze

  def buli_permitted?(user)
    ph = user.permission_hash
    ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
  end

  def track_public_view
    DailyMetric.increment!('public_views')
  end

  def league_params
    params.require(:league).permit(:before_deadline, :deadline, :female, :age_group, :game_operation_id,
                                   :league_category_id, :league_class_id, :league_system_id, :name, :order_key,
                                   :short_name, :enable_scorer, :field_size, :league_modus, :league_id_preseason,
                                   :league_id_preround, :has_preround, :preround_point_modus, :preround_scorer_modus,
                                   :league_id_direct_encounters,
                                   :table_modus, :direct_comparison, :periods, :period_length, :overtime_length,
                                   :banner_link_url,
                                   required_documents: [])
  end
end
