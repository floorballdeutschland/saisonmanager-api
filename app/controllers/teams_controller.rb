class TeamsController < ApplicationController
  skip_before_action :authenticate_user, only: %i[show stats matches]
  before_action :authenticate_public_request, only: %i[show stats matches]

  # GET /teams
  def index
    @teams = Team.all

    render json: @teams
  end

  # GET /teams/1.json
  def show
    games = Game.by_team_id(params[:id])

    respond_to do |format|
      format.ics do
        ical = ::Icalendar::Calendar.new
        events = games.map(&:ical)
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

  def stats
    team = Team.find(params[:id])
    team_season_id = season_id_for(team)
    return render_team_without_league if team_season_id.blank?

    # All leagues this team participates in (main league + cup leagues)
    leagues = team.leagues.where(season_id: team_season_id).to_a
    primary_league = leagues.first

    # Evaluate scorer directly from the team's season's ended games
    current_season_games = Game.by_team_id(team.id)
                               .where(ended: true)
                               .joins(game_day: :league)
                               .where(leagues: { season_id: team_season_id })

    # Die öffentliche Scorerliste folgt der Liga-Einstellung enable_scorer (in
    # der Altersklasse U13 und jünger per Vorgabe aus). Gefiltert wird pro
    # beitragender Liga, nicht pauschal über das Team: Spielt ein Team zusätzlich
    # in einer Liga ohne öffentliche Scorerliste (häufig bei Relegation und
    # Qualifikation, `enable_scorer` hat den Default false), bleiben die Punkte
    # aus den übrigen Ligen sichtbar, so wie sie unter `leagues/:id/scorer`
    # ohnehin öffentlich sind. Die Team-Summen unten zählen weiter alle Spiele,
    # sie sind keine personenbezogene Rangliste.
    visible_league_ids = leagues.select(&:enable_scorer).map(&:id)

    team_scorer_data = {}
    visible_scorer_data = {}
    current_season_games.includes(:game_day).each do |game|
      next if game.result.nil?

      begin
        game_score = game.evaluate_scorer
        visible = visible_league_ids.include?(game.game_day.league_id)
        game_score.each do |player_id, score|
          next unless score[:team_id] == team.id

          add_scorer_score(team_scorer_data, player_id, score)
          add_scorer_score(visible_scorer_data, player_id, score) if visible
        end
      rescue StandardError => e
        Rails.logger.warn("evaluate_scorer failed for game #{game.id}: #{e.message}")
      end
    end

    scorer_visible = visible_league_ids.present?
    scorer_list = scorer_visible ? scorer_entries(visible_scorer_data) : []
    totals_list = scorer_entries(team_scorer_data)

    # Recent results (last 10 ended games across all leagues, ordered by game day date)
    recent_games = Game.by_team_id(team.id)
                       .where(ended: true)
                       .joins(game_day: :league)
                       .where(leagues: { season_id: team_season_id })
                       .includes(game_day: :league)
                       .order('game_days.date DESC')
                       .limit(10)
                       .map do |g|
      result = g.result
      {
        game_id:            g.id,
        game_number:        g.game_number,
        home_team_name:     g.home_team_name,
        home_team_logo:     g.home_team&.logo_small_url_fallback,
        guest_team_name:    g.guest_team_name,
        guest_team_logo:    g.guest_team&.logo_small_url_fallback,
        home_goals:         result&.dig(:home_goals),
        guest_goals:        result&.dig(:guest_goals),
        date:               g.game_day.date,
        league_id:          g.game_day.league.id,
        league_name:        g.game_day.league.name,
        league_short_name:  g.game_day.league.short_name
      }
    end

    # Upcoming games (next 10 across all leagues, not yet started)
    upcoming_games = Game.by_team_id(team.id)
                         .where(started: false)
                         .joins(game_day: :league)
                         .where(leagues: { season_id: team_season_id })
                         .where('game_days.date >= ?', Date.today)
                         .includes(game_day: :league)
                         .order('game_days.date ASC')
                         .limit(10)
                         .map do |g|
      {
        game_id:            g.id,
        game_number:        g.game_number,
        home_team_name:     g.home_team_name,
        home_team_logo:     g.home_team&.logo_small_url_fallback,
        guest_team_name:    g.guest_team_name,
        guest_team_logo:    g.guest_team&.logo_small_url_fallback,
        date:               g.game_day.date,
        start_time:         g.start_time,
        league_id:          g.game_day.league.id,
        league_name:        g.game_day.league.name,
        league_short_name:  g.game_day.league.short_name
      }
    end

    leagues_info = leagues.map do |l|
      {
        id: l.id,
        name: l.name,
        short_name: l.short_name,
        game_operation_slug: l.game_operation.slug
      }
    end

    team_info = if primary_league
                  {
                    id: team.id,
                    name: team.name,
                    short_name: team.short_name,
                    logo_url: team.logo_url_fallback,
                    logo_small: team.logo_small_url_fallback,
                    league_id: primary_league.id,
                    league_name: primary_league.name,
                    leagues: leagues_info,
                    game_operation_id: primary_league.game_operation.id,
                    game_operation_name: primary_league.game_operation.name,
                    game_operation_short_name: primary_league.game_operation.short_name,
                    game_operation_slug: primary_league.game_operation.slug
                  }
                else
                  { id: team.id, name: team.name, short_name: team.short_name, league_name: nil, leagues: [] }
                end

    render json: {
      team:           team_info,
      scorer:         scorer_list,
      scorer_visible:,
      recent_games:,
      upcoming_games:,
      totals: {
        games:           totals_list.sum { |s| s[:games] } / [totals_list.size, 1].max, # avg
        goals:           totals_list.sum { |s| s[:goals] },
        assists:         totals_list.sum { |s| s[:assists] },
        penalty_minutes: totals_list.sum { |s| s[:penalty_minutes] }
      }
    }
  end

  # GET /api/v2/teams/:id/matches
  # Alle Spiele eines Teams über ALLE Wettbewerbe (Haupt-/Aufstiegsrunde, Playoffs,
  # Pokal …) der Saison des Teams als strukturierte JSON-Liste – im Gegensatz zum
  # iCal-Export (#show) und der gekappten Übersicht (#stats). Öffentlich (X-Api-Key).
  def matches
    team = Team.find(params[:id])
    team_season_id = season_id_for(team)
    return render_team_without_league if team_season_id.blank?

    leagues = team.leagues.where(season_id: team_season_id).to_a
    leagues_info = leagues.map do |l|
      {
        id: l.id,
        name: l.name,
        short_name: l.short_name,
        game_operation_id: l.game_operation.id,
        game_operation_name: l.game_operation.name,
        game_operation_slug: l.game_operation.slug
      }
    end

    games = Game.by_team_id(team.id)
                .joins(game_day: :league)
                .where(leagues: { season_id: team_season_id })
                # club je game_day, weil schedule_item game_day.hosting_club
                # (= club.name) liest; home_team/guest_team + deren club, weil
                # logo_url_fallback bei fehlendem Team-Logo auf club.logo_url fällt.
                .includes(game_day: %i[arena league club], home_team: :club, guest_team: :club)
                .order('game_days.date ASC')

    matches = games.map do |g|
      league = g.game_day.league
      # schedule_item liefert bereits Halle, Ergebnis/Status (started/ended/state),
      # notice_type und Teamnamen/-logos; hier ergänzt um IDs, Wettbewerbszuordnung
      # und einen groben, konsumentenfreundlichen Status.
      g.schedule_item.merge(
        home_team_id: g.home_team_id,
        home_team_club_id: g.home_team&.club_id,
        guest_team_id: g.guest_team_id,
        guest_team_club_id: g.guest_team&.club_id,
        league_id: league.id,
        league_name: league.name,
        league_short_name: league.short_name,
        status: match_status(g)
      )
    end

    render json: {
      team: {
        id: team.id,
        name: team.name,
        short_name: team.short_name,
        logo_url: team.logo_url_fallback,
        logo_small: team.logo_small_url_fallback
      },
      season_id: team_season_id,
      leagues: leagues_info,
      matches:
    }
  end

  # Team-Details inkl. Kontaktdaten (full_hash(true)) – nur Admin/SBK des
  # Spielbetriebs sowie VM/TM der eigenen Mannschaft.
  def admin_get_team
    if current_user
      team = Team.find(params[:id])

      if can_read_admin_team?(team)
        render json: team.full_hash(true)
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_team_update
    if current_user
      create_modus = params[:id].zero?
      # check: game operation permission if create_modus
      #   has: create team for that go?
      #   else : unpermitted!
      # check: league permission unless create_modus
      #   has: update league for that league?
      #   else : unpermitted!
      l = League.find(params[:league_id])

      if create_modus && League.find(params[:league_id])&.game_operation&.user_permissions(current_user)&.include?(:create_team) # create
        if params[:team][:cup_leagues].present?
          valid_ids = League.where(game_operation_id: l.game_operation_id).pluck(:id)
          invalid = Array(params[:team][:cup_leagues]).map(&:to_i) - valid_ids
          return render json: { errors: ["Ungültige Liga-IDs: #{invalid.join(', ')}"] }, status: :unprocessable_entity if invalid.any?
        end

        tp = team_params
        team = Team.create(tp)

        render json: team, status: :created
      elsif !create_modus && Team.find(params[:id])&.user_permissions(current_user)&.include?(:update_team) # update
        team = Team.find(params[:id])
        if params[:team][:cup_leagues].present?
          valid_ids = League.where(game_operation_id: team.league.game_operation_id).pluck(:id)
          invalid = Array(params[:team][:cup_leagues]).map(&:to_i) - valid_ids
          return render json: { errors: ["Ungültige Liga-IDs: #{invalid.join(', ')}"] }, status: :unprocessable_entity if invalid.any?
        end
        if team.update(team_params)
          render json: team
        else
          render json: team.errors, status: :unprocessable_entity
        end
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  # DELETE /admin/teams/:id
  # Löscht ein Team endgültig – aber nur, wenn keine Spieler/Lizenzen und keine
  # Spiele daran hängen, damit keine Historie verloren geht.
  def destroy
    return render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized unless current_user

    team = Team.find(params[:id])

    unless team.user_permissions(current_user).include?(:delete_team)
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    if Player.find_by_team_id(team.id).present?
      return render json: { message: 'Team kann nicht gelöscht werden: Es sind noch Spieler bzw. Lizenzen zugeordnet.' },
                    status: :unprocessable_entity
    end

    if Game.by_team_id(team.id).exists?
      return render json: { message: 'Team kann nicht gelöscht werden: Es existieren noch Spiele oder Ergebnisse.' },
                    status: :unprocessable_entity
    end

    if PlayerSuspension.where(team_id: team.id).exists?
      return render json: { message: 'Team kann nicht gelöscht werden: Es existieren noch Sperren, die diesem Team zugeordnet sind.' },
                    status: :unprocessable_entity
    end

    if RefereeFeedback.where(team_id: team.id).exists?
      return render json: { message: 'Team kann nicht gelöscht werden: Es existiert noch Schiedsrichter-Feedback für dieses Team.' },
                    status: :unprocessable_entity
    end

    team.destroy!
    head :no_content
  rescue ActiveRecord::InvalidForeignKey => e
    Rails.logger.info("Team##{params[:id]} destroy blocked by FK: #{e.message}")
    render json: { message: 'Team kann nicht gelöscht werden: Es existieren noch verknüpfte Einträge ' \
                            '(z.B. Spieltag-Bestätigungen).' },
           status: :unprocessable_entity
  end

  def license_list
    team = Team.find(params[:id])

    hash = league.short_hash true

    render json: team.licenses(false, true, :short)
  end

  def admin_upload_logo
    if current_user
      team = Team.find(params[:id])

      unless team.user_permissions(current_user).include?(:update_team)
        return render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

      unless params[:logo].present?
        return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity
      end

      if (error = logo_upload_error(params[:logo]))
        return render json: { message: error }, status: :unprocessable_entity
      end

      team.logo.attach(params[:logo])
      render json: { logo_url: team.logo_url, logo_small_url: team.logo_small_url }
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def team_params
    params.require(:team).permit(:club_id, :contact_email, :contact_person, :league_id, :name, :short_name, :syndicate,
                                 syndicate_clubs: [], cup_leagues: [])
  end

  private

  # Die league_id eines Teams pinnt es bereits auf genau eine Saison (Teams
  # werden pro Saison neu importiert) – daher die Saison des Teams und nicht
  # current_season_id, das für Teams vergangener Saisons leer ist.
  #
  # team.league ist nil, wenn league_id leer ist oder auf eine gelöschte Liga
  # zeigt; dann liefern die Pokal-Ligen die Saison. Fehlt jede Liga, gibt es
  # keine Saison und damit keine Daten (vorher 500, Sentry SAISONMANAGER-1C).
  def season_id_for(team)
    team.league&.season_id || team.leagues.first&.season_id
  end

  def render_team_without_league
    render json: { success: false, message: 'Mannschaft ist keiner Liga zugeordnet.' },
           status: :not_found
  end

  SCORER_COUNTERS = %i[games goals assists penalty_2 penalty_2and2 penalty_5 penalty_10
                       penalty_ms_tech penalty_ms_full penalty_ms1 penalty_ms2 penalty_ms3].freeze

  # Addiert die Werte eines Spiels auf den Zwischenstand eines Spielers.
  def add_scorer_score(store, player_id, score)
    if store[player_id]
      SCORER_COUNTERS.each do |k|
        store[player_id][k] = (store[player_id][k] || 0) + (score[k] || 0)
      end
    else
      store[player_id] = score.dup
    end
  end

  # Baut aus dem Zwischenstand die sortierte Scorerliste inkl. Spielernamen.
  def scorer_entries(store)
    entries = store.values
    players = Player.where(id: entries.map { |s| s[:player_id] }).index_by(&:id)

    entries
      .sort_by { |s| [-(s[:goals] + s[:assists]), -s[:goals], -s[:games]] }
      .filter_map do |s|
        player = players[s[:player_id]]
        next if player.nil?

        {
          player_id:    s[:player_id],
          first_name:   player.first_name,
          last_name:    player.last_name,
          games:        s[:games],
          goals:        s[:goals],
          assists:      s[:assists],
          scorer_points: s[:goals] + s[:assists],
          penalty_minutes: (s[:penalty_2] * 2) + (s[:penalty_2and2] * 4) +
                           (s[:penalty_5] * 5) + (s[:penalty_10] * 10) +
                           (s[:penalty_ms_tech] + s[:penalty_ms_full] +
                            s[:penalty_ms1] + s[:penalty_ms2] + s[:penalty_ms3]) * 25
        }
      end
  end

  # Grober Spielstatus für API-Konsumenten. Feinere Signale (started/ended/state,
  # notice_type, result/result_string) liefert schedule_item zusätzlich.
  def match_status(game)
    return 'cancelled' if game.notice_type == 'Canceled'
    return 'finished' if game.ended
    return 'running' if game.started

    'scheduled'
  end

  def can_read_admin_team?(team)
    ph = current_user.permission_hash
    go_id = team.league&.game_operation_id.to_i
    return true if ph[:admin].to_a.intersect?([0, go_id]) || ph[:sbk].to_a.intersect?([0, go_id])
    return true if ph[:vm].present? && ph[:vm].intersect?(team.all_club_ids)

    ph[:tm].present? && ph[:tm].include?(team.id)
  end
end
