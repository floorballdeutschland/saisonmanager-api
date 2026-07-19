class LeaguesController < ApplicationController
  skip_before_action :authenticate_user, except: %i[admin_league_index admin_upload_banner admin_delete_banner]
  before_action :authenticate_public_request, except: %i[admin_league_index admin_upload_banner admin_delete_banner]
  after_action :track_public_view,
               only: %i[schedule current_schedule game_day_schedule table grouped_table scorer],
               if: -> { response.successful? }

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

      if league && admin_or_sbk_for_league?(league)
        render json: league.hash_with_teams
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end
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
        # Anzeige-Namen der Klasse/Kategorie einfrieren, damit eine spätere
        # Umbenennung in Setting alte Ligen nicht rückwirkend verändert.
        lp[:league_class_name] = Setting.league_class(lp[:league_class_id]).presence if lp[:league_class_id].present?
        lp[:league_category_name] = Setting.league_category(lp[:league_category_id]).presence if lp[:league_category_id].present?
        league = League.create(lp)

        if league.persisted?
          render json: league, status: :created
        else
          render json: { message: league.errors.full_messages.join(', ') }, status: :unprocessable_entity
        end
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
          # message-Key, damit der Frontend-ErrorInterceptor den Text durchreicht
          render json: { message: league.errors.full_messages.join(', ') }, status: :unprocessable_entity
        end
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_game_schedule
    if current_user
      league = League.find(params[:id])

      if league && admin_or_sbk_for_league?(league)
        # :games hier bewusst NICHT preloaden – full_hash(true) lädt die Spiele
        # ohnehin neu (mit eigener .order + Team/Club-includes), der Preload
        # wäre verworfen.
        items = league.game_days.includes(:arena, :club).map do |gd|
                  gd.full_hash(true)
                end.sort_by do |gd|
                  first_game_number = gd[:games].present? ? gd[:games].first[:number].to_i : 0
                  [gd[:number].to_i, gd[:date], first_game_number]
                end
        render json: items
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
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

            # Ein Re-Import ist erlaubt, solange noch kein Spiel begonnen/gespielt
            # wurde – der bestehende (nur geplante) Spielplan wird dann unten
            # komplett ersetzt. Sobald ein Spiel begonnen/gespielt ist, wird der
            # gesamte Import blockiert (kein Teil-Überschreiben).
            if league_schedule_started?(league)
              errors << 'Liga hat bereits begonnene oder gespielte Spiele – ein erneuter Import ist nicht mehr möglich.'
            end

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
        begin
          # Löschen + Neuanlegen atomar: schlägt das Neuanlegen fehl, rollt die
          # Transaktion inkl. Löschung zurück; der bisherige Spielplan bleibt
          # erhalten. Da die Parse-Fehlerprüfung oben schon durchlaufen ist,
          # wird nur bei fehlerfreiem Import gelöscht/ersetzt.
          ActiveRecord::Base.transaction do
            rebuild_schedule!(league, game_days, games)
          end

          render json: { errors:, warnings: }
        rescue ActiveRecord::RecordInvalid => e
          # Neuanlage fehlgeschlagen -> Transaktion wurde zurückgerollt, der
          # bestehende Spielplan ist unverändert. Sauberer Fehler statt 500.
          render json: { message: { errors: ["Import fehlgeschlagen, Spielplan unverändert: #{e.message}"],
                                    warnings: }.to_json },
                 status: :bad_request
        end
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
            'season_id' => league.season_id,
            'league_class_id' => league.league_class_id,
            'history' => [{
              'license_status_id' => License::APPROVED,
              'created_by' => current_user.id,
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

  # Stammdaten-Spalten, die bei der Liga-Kopie (Saisonwechsel, #69) 1:1
  # übernommen werden. Bewusst NICHT kopiert:
  #   - season_id (wird auf die aktuelle Saison gesetzt)
  #   - deadline (+1 Jahr verschoben)
  #   - league_id_preseason (zeigt auf die Quell-Liga selbst),
  #     league_id_preround / league_id_direct_encounters (zeigen auf Ligen der
  #     Quellsaison und müssen neu gesetzt werden)
  #   - point_corrections (Team-IDs der Quellsaison als Keys)
  #   - banner_link_url (das Banner-Attachment wird nicht mitkopiert)
  #   - legacy_league / legacy_ref / created_by / updated_by
  COPYABLE_LEAGUE_ATTRIBUTES = %w[
    game_operation_id name short_name league_category_id league_class_id
    league_system_id league_type league_modus table_modus has_preround
    preround_point_modus preround_scorer_modus female enable_scorer field_size
    periods period_length overtime_length order_key before_deadline
    direct_comparison required_documents age_group parental_consent_required
    game_duration_minutes referee_feedback_enabled
  ].freeze

  # POST /admin/leagues/:id/copy
  # Kopiert eine Liga (Stammdaten, optional Teams) in die aktuelle Saison (#69).
  # Spieltage, Spiele und Ergebnisse werden bewusst nicht kopiert.
  def admin_copy
    return render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized unless current_user

    source = find_league_or_not_found or return

    # Berechtigung wie beim Anlegen einer Liga (admin_league_update,
    # create-Zweig), gespiegelt am Verband der Quell-Liga.
    unless source.game_operation&.user_permissions(current_user)&.include?(:create_league)
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    # league_class_id kann in Altbeständen/Importen un-normalisierte Werte
    # tragen (z. B. "10"); auf die kanonischen Codes abbilden, bevor damit
    # geprüft und kopiert wird. Sonst bricht save! die Kopie mit
    # "League class is not included in the list" ab (#114) – und der
    # Buli-Berechtigungscheck würde einen Legacy-Wert wie "10" (=> 1fbl)
    # fälschlich durchlassen.
    normalized_class_id = League.normalize_class_id(source.league_class_id, source.name)

    if BUNDESLIGA_CLASSES.include?(normalized_class_id) && !buli_permitted?(current_user)
      return render json: { message: 'Keine Berechtigung für diese Ligaklasse' }, status: :forbidden
    end

    # Selektive Team-Übernahme: team_ids listet genau die zu kopierenden Teams
    # (leere Liste => nur die Liga, ohne Teams). Fehlt der Parameter ganz,
    # greift der ältere include_teams-Boolean (alle Teams / keine) als
    # Rückfallebene für Altclients.
    copy_team_ids =
      if params.key?(:team_ids)
        Array(params[:team_ids]).map(&:to_i).uniq
      elsif ActiveModel::Type::Boolean.new.cast(params[:include_teams])
        Team.where(league_id: source.id).pluck(:id)
      else
        []
      end

    attrs = source.attributes.slice(*COPYABLE_LEAGUE_ATTRIBUTES)
    attrs['season_id'] = Setting.current_season_id
    attrs['deadline'] = source.deadline&.advance(years: 1)
    attrs['league_id_preseason'] = source.id
    attrs['legacy_league'] = false
    attrs['league_class_id'] = normalized_class_id
    # Anzeige-Namen wie beim Anlegen aus dem aktuellen Setting einfrieren;
    # Fallback auf die in der Quell-Liga eingefrorenen Namen.
    if normalized_class_id.present?
      attrs['league_class_name'] = Setting.league_class(normalized_class_id).presence || source.league_class_name
    end
    if source.league_category_id.present?
      attrs['league_category_name'] = Setting.league_category(source.league_category_id).presence ||
                                      source.league_category_name
    end

    new_league = League.new(attrs)

    begin
      ActiveRecord::Base.transaction do
        new_league.save!

        if copy_team_ids.any?
          # Nur direkt zugeordnete Teams (league_id) der Quell-Liga –
          # Pokal-Zuordnungen über Team#cup_leagues zeigen auf Team-Datensätze
          # anderer Ligen und werden bewusst nicht mitkopiert. TM-Zuordnungen
          # (User#teams) bleiben unangetastet und müssen neu gesetzt werden.
          # Die league_id-Bedingung verhindert zugleich, dass fremde Team-IDs
          # über den Parameter eingeschleust werden.
          Team.where(id: copy_team_ids, league_id: source.id).find_each do |team|
            Team.create!(
              league_id:       new_league.id,
              club_id:         team.club_id,
              name:            team.name,
              short_name:      team.short_name,
              syndicate:       team.syndicate,
              syndicate_clubs: team.syndicate_clubs,
              contact_person:  team.contact_person,
              contact_email:   team.contact_email,
              approved:        false
            )
          end
        end
      end
    rescue ActiveRecord::RecordInvalid => e
      # message-Key, damit der Frontend-ErrorInterceptor den Text durchreicht
      return render json: { message: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    render json: new_league, status: :created
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
  def schedule
    id = params[:id]

    schedule = Rails.cache.fetch("leagues/#{id}/schedule", expires_in: 5.minutes) do
      @league = League.find(id)
      @league.schedule
    end

    # 15s sind kurz genug, dass die 30s-Live-Polls der öffentlichen Ansichten
    # frisch bleiben. Bewusst private (kein public): delay_live_scores variiert
    # die Antwort je API-Key UND je Cookie-Session (eingeloggt = realtime) –
    # ein Shared Cache/CDN dürfte diese Varianten nicht mischen. Der Browser-
    # Cache pro Nutzer reicht für das Durchklick-Ziel völlig aus.
    expires_in 15.seconds
    render json: delay_live_scores(schedule)
  end

  # GET /leagues/1/game_days/15/schedule
  def game_day_schedule
    id = params[:id]
    # to_i, damit nur normalisierte Werte in den Cache-Key fließen (und der
    # Key exakt dem entspricht, den Game#flush_league_caches löscht).
    game_day_number = params[:game_day_number].to_i

    schedule = Rails.cache.fetch("leagues/#{id}/game_day_schedule/#{game_day_number}",
                                 expires_in: 5.minutes) do
      League.find(id).game_day_schedule(game_day_number)
    end

    # delay_live_scores wie bei schedule/current_schedule: ohne den Filter
    # umging dieser Endpunkt die Ergebnis-Verzögerung für Nicht-Realtime-Keys.
    # private wie dort (Variante hängt an Key UND Cookie-Session).
    expires_in 15.seconds
    render json: delay_live_scores(schedule)
  end

  # GET /leagues/1/game_days/current/schedule
  def current_schedule
    id = params[:id]

    current_schedule = Rails.cache.fetch("leagues/#{id}/current_schedule", expires_in: 5.minutes) do
      @league = League.find(id)
      @league.current_schedule
    end

    # private wie schedule (Variante hängt an API-Key UND Cookie-Session).
    expires_in 15.seconds
    render json: delay_live_scores(current_schedule)
  end

  # GET /leagues/1/scorer
  def scorer
    id = params[:id]

    scorer = Rails.cache.fetch("leagues/#{id}/scorer", expires_in: 5.minutes) do
      League.find(id).scorer
    end

    # Scorer/Tabellen zählen nur beendete Spiele – 30s Browser-Cache macht
    # das Durchklicken (Tabelle ↔ Scorer ↔ Spielplan) requestfrei.
    expires_in 30.seconds, public: true
    render json: scorer
  end

  # GET /leagues/1/table
  def table
    id = params[:id]

    table = Rails.cache.fetch("leagues/#{id}/table", expires_in: 5.minutes) do
      League.find(id).table
    end

    expires_in 30.seconds, public: true
    render json: table
  end

  def grouped_table
    id = params[:id]

    grouped_table = Rails.cache.fetch("leagues/#{id}/grouped_table", expires_in: 5.minutes) do
      League.find(id).grouped_table
    end

    expires_in 30.seconds, public: true
    render json: grouped_table
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

    # Ansetzung durch die RSK: national (kein Landesverband, z. B. FD) immer aktiv,
    # sonst entscheidet das LV-Flag referee_assignment_enabled.
    sa = league.game_operation&.state_association
    referee_assignment_enabled = sa.nil? || sa.referee_assignment_enabled?

    render json: {
      arenas: Arena.active.order(:city, :name).sort_by { |a| a.city.present? ? 0 : 1 }.map(&:full_hash),
      teams: league.teams.map(&:full_hash),
      clubs: teams.map(&:all_clubs).flatten.uniq.map(&:full_hash),
      referee_assignment_enabled: referee_assignment_enabled
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

  def admin_import_teams
    league = find_league_or_not_found or return
    unless league.user_permissions(current_user).include?(:update_league)
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    source_league = League.find_by(id: params[:source_league_id])
    return render json: { message: 'Quell-Liga nicht gefunden' }, status: :not_found unless source_league

    # Grundcheck: nur Admin oder SBK darf Daten aus beliebigen Ligen lesen.
    # Eine feinere GO-Einschränkung entfällt bewusst, da das Feature explizit
    # das Importieren aus Ligen anderer LVs (z.B. für Playoffs) ermöglicht.
    ph = current_user.permission_hash
    unless ph[:admin].present? || ph[:sbk].present?
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    top_n = params[:top_n].to_i
    ranked_team_ids = source_league.table.map { |e| e[:team_id] }
    ranked_team_ids = ranked_team_ids.first(top_n) if top_n.positive?

    existing_club_ids = league.teams.pluck(:club_id).to_set
    source_teams = Team.where(id: ranked_team_ids).index_by(&:id)

    imported = 0
    skipped  = 0
    failed   = 0

    ranked_team_ids.each do |team_id|
      source_team = source_teams[team_id]
      next unless source_team

      if existing_club_ids.include?(source_team.club_id)
        skipped += 1
        next
      end

      new_team = Team.new(
        club_id:        source_team.club_id,
        league_id:      league.id,
        name:           source_team.name,
        short_name:     source_team.short_name,
        contact_person: source_team.contact_person.presence || '',
        contact_email:  source_team.contact_email.presence || '',
        approved:       false
      )

      if new_team.save
        imported += 1
        existing_club_ids.add(source_team.club_id)
      else
        failed += 1
      end
    end

    render json: { imported: imported, skipped: skipped, failed: failed }
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

  # Admin/SBK des Spielbetriebs der Liga (0 = global) – Scope für die reinen
  # Verwaltungs-Reads (Team-Index, Spielplan-Verwaltung).
  def admin_or_sbk_for_league?(league)
    ph = current_user.permission_hash
    go_id = league.game_operation_id.to_i
    ph[:admin].to_a.intersect?([0, go_id]) || ph[:sbk].to_a.intersect?([0, go_id])
  end

  def track_public_view
    fingerprint = [request.remote_ip, params[:controller], params[:action], params[:id]].compact.join('|')
    cache_key = "analytics:view:#{Digest::SHA256.hexdigest(fingerprint)}"
    # unless_exist macht read+write atomar: nur der erste parallele Request gewinnt das Write
    # und darf inkrementieren; alle anderen sehen das Cache-Eintragsergebnis und brechen ab.
    return unless Rails.cache.write(cache_key, true, expires_in: 30.minutes, unless_exist: true)

    DailyMetric.increment!('public_views')
  end

  def league_params
    params.require(:league).permit(:before_deadline, :deadline, :female, :age_group, :game_operation_id,
                                   :league_category_id, :league_class_id, :league_system_id, :name, :order_key,
                                   :short_name, :enable_scorer, :field_size, :league_modus, :league_id_preseason,
                                   :league_id_preround, :has_preround, :preround_point_modus, :preround_scorer_modus,
                                   :league_id_direct_encounters,
                                   :table_modus, :direct_comparison, :periods, :period_length, :overtime_length,
                                   :game_duration_minutes,
                                   :banner_link_url, :parental_consent_required,
                                   :referee_feedback_enabled,
                                   required_documents: [])
  end

  # Entfernt Ergebnis-Daten für laufende Spiele bei nicht-Echtzeit-API-Keys.
  # Der Cache bleibt global – die Filterung erfolgt nach dem Cache-Fetch.
  def delay_live_scores(schedule)
    return schedule unless api_key_request? && !@api_key&.realtime

    schedule.map do |game|
      next game unless game[:state].to_s == 'running'

      game.merge(result: nil, result_string: nil)
    end
  end

  # True, wenn in der Liga schon ein Spiel begonnen/gespielt wurde – dann ist
  # ein (überschreibender) Spielplan-Import nicht mehr erlaubt.
  def league_schedule_started?(league)
    Game.where(game_day_id: league.game_days.select(:id)).played_or_started.exists?
  end
  private :league_schedule_started?

  # Löscht den bestehenden (noch ungespielten) Spielplan einer Liga: erst Spiele
  # einzeln (damit dependent: :destroy für Ansetzung/Bericht/Scan/Feedback/
  # Verfahrensvorschlag greift und die Liga-Caches per after_commit invalidiert
  # werden), dann die Spieltage inkl. deren Bestätigungen/Sekretär-Links.
  def delete_existing_schedule!(league)
    game_day_ids = league.game_days.ids
    Game.where(game_day_id: game_day_ids).find_each(&:destroy!)
    GameDay.where(id: game_day_ids).find_each(&:destroy!)
  end
  private :delete_existing_schedule!

  # Ersetzt den Spielplan: löscht den bestehenden und legt die geparsten
  # Spieltage/Spiele neu an. create! (bang), damit ein Fehlschlag über die
  # umgebende Transaktion zurückrollt. Erwartet die vom Parser aufgebauten
  # game_days-/games-Hashes; hinterlegt je Spieltag den erzeugten Record.
  def rebuild_schedule!(league, game_days, games)
    delete_existing_schedule!(league)

    game_days.each { |k, v| game_days[k][:gd] = GameDay.create!(v) }

    games.each do |k, v|
      gd_id = game_days[k][:gd].id
      v.each do |game_hash|
        Game.create!(game_hash.merge(game_day_id: gd_id, started: false, ended: false, game_ended: false))
      end
    end
  end
  private :rebuild_schedule!
end
