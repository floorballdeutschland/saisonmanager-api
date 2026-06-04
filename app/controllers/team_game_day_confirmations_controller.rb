class TeamGameDayConfirmationsController < ApplicationController
  before_action :authenticate_user

  AUTO_CONFIRM_HOURS = 48

  # GET /api/v2/user/team_game_days
  # Spieltage, an denen der/die Benutzer:in mindestens eine Gastmannschaft (Team
  # eines Gastvereins) als TM oder VM verantwortet. Jede Gastmannschaft bestätigt
  # eigenständig; bleibt die Bestätigung 48 h aus, gilt sie automatisch als erteilt.
  def index
    return render json: [] if managed_team_ids.empty?

    game_day_ids = GameDay
                   .joins(:games)
                   .where('games.home_team_id IN (:t) OR games.guest_team_id IN (:t)', t: managed_team_ids)
                   .where("TO_DATE(game_days.date, 'YYYY-MM-DD') >= ?", 60.days.ago.to_date)
                   .distinct
                   .pluck(:id)

    game_days = GameDay
                .where(id: game_day_ids)
                .includes(
                  :arena, :club,
                  games: %i[home_team guest_team],
                  league: { game_operation: { state_association: :checklist_items } }
                )
                .order('game_days.date DESC')

    confirmations = GameDayTeamConfirmation
                    .where(game_day_id: game_day_ids)
                    .group_by(&:game_day_id)

    payload = game_days.filter_map do |gd|
      teams = managed_guest_teams(gd)
      next if teams.empty?

      game_day_json(gd, teams, confirmations[gd.id] || [])
    end

    render json: payload
  end

  # POST /api/v2/user/team_game_days/:game_day_id/teams/:team_id/confirm
  def confirm
    game_day = GameDay.find(params[:game_day_id])
    team = Team.find(params[:team_id])

    unless managed_guest_team?(game_day, team)
      return render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Idempotent: bereits abgegebene Bewertung unverändert zurückgeben.
    existing = GameDayTeamConfirmation.find_by(game_day: game_day, team: team)
    return render json: confirmation_payload(existing) if existing

    items = checklist_items_for(game_day)
    if items.empty?
      return render json: { error: 'Für diesen Spieltag ist keine Checkliste hinterlegt.' },
                    status: :unprocessable_entity
    end

    # properly_conducted muss explizit als Boolean angegeben werden – sonst würde
    # eine Meldung mit fehlendem Flag still als "ordnungsgemäß" gespeichert.
    properly = params[:properly_conducted]
    unless [true, false].include?(properly)
      return render json: { error: 'Angabe ordnungsgemäß (true/false) erforderlich.' },
                    status: :unprocessable_entity
    end

    threshold = last_game_start(game_day)
    if threshold && Time.current < threshold
      return render json: { error: 'Bewertung erst ab Beginn des letzten Spiels möglich.' },
                    status: :unprocessable_entity
    end

    if auto_confirmed?(game_day)
      return render json: { error: 'Spieltag wurde automatisch bestätigt', auto_confirmed: true },
                    status: :unprocessable_entity
    end

    # Bei "nicht ordnungsgemäß" muss die Checkliste vollständig mit Ja/Nein beantwortet sein.
    answers = []
    unless properly
      answers = normalize_answers(params[:answers], items)
      if answers.nil?
        return render json: { error: 'Bitte alle Checklisten-Fragen mit Ja/Nein beantworten.' },
                      status: :unprocessable_entity
      end
    end

    confirmation = GameDayTeamConfirmation.create!(
      game_day: game_day,
      team: team,
      confirmed_at: Time.current,
      properly_conducted: properly,
      checklist_answers: answers,
      confirmed_by_user_id: current_user.id
    )

    notify_sbk_of_veto(game_day, team, confirmation) unless properly

    render json: confirmation_payload(confirmation), status: :created
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue ActiveRecord::RecordNotUnique
    existing = GameDayTeamConfirmation.find_by(game_day: game_day, team: team)
    render json: confirmation_payload(existing) if existing
  end

  private

  # Team-IDs, die der/die Benutzer:in als Teammanager (direkt) oder als
  # Vereinsmanager (alle Teams der eigenen Vereine) verantwortet.
  def managed_team_ids
    @managed_team_ids ||= begin
      ids = tm_team_ids.dup
      ids += Team.where(club_id: managed_club_ids).pluck(:id) if managed_club_ids.present?
      ids.uniq
    end
  end

  def tm_team_ids
    @tm_team_ids ||= Array(current_user.permission_hash[:tm]).map(&:to_i)
  end

  def managed_club_ids
    @managed_club_ids ||= Array(current_user.permission_hash[:vm]).map(&:to_i)
  end

  # Gastmannschaften des Spieltags, die der/die Benutzer:in verantwortet.
  def managed_guest_teams(game_day)
    teams = game_day.games.flat_map { |g| [g.home_team, g.guest_team] }.compact.uniq
    teams.select { |t| managed_guest_team?(game_day, t) }
  end

  # True, wenn `team` am Spieltag spielt, NICHT zum Ausrichterverein gehört und
  # der/die Benutzer:in es als TM (per Team-ID) oder VM (per Vereins-ID) verantwortet.
  def managed_guest_team?(game_day, team)
    return false if team.nil?
    return false if team.club_id == game_day.club_id
    return false unless game_day.games.any? { |g| g.home_team_id == team.id || g.guest_team_id == team.id }

    tm_team_ids.include?(team.id) || managed_club_ids.include?(team.club_id)
  end

  # Beginn des letzten Spiels eines Spieltags (spätester Anpfiff in Europe/Berlin).
  # Bestätigung ist erst ab diesem Zeitpunkt möglich. nil, wenn keine Startzeit
  # ermittelbar ist (dann keine zeitliche Sperre).
  def last_game_start(game_day)
    return nil if game_day.date.blank?

    tz = ActiveSupport::TimeZone['Europe/Berlin']
    game_day.games.filter_map do |g|
      next if g.start_time.blank?

      tz.parse("#{game_day.date} #{g.start_time}")
    rescue ArgumentError, TypeError
      nil
    end.max
  end

  def auto_confirmed?(game_day)
    return false if game_day.date.blank?

    date = Date.parse(game_day.date)
    date.to_datetime.end_of_day + AUTO_CONFIRM_HOURS.hours < Time.current
  rescue ArgumentError, TypeError => e
    Rails.logger.error(
      "[TeamGameDayConfirmations] auto_confirmed? failed for game_day_id=#{game_day.id} " \
      "date=#{game_day.date.inspect}: #{e.class}: #{e.message}"
    )
    false
  end

  # Spieltagscheckliste des LV der Liga/des Spielverbunds (nicht des Ausrichtervereins).
  def checklist_items_for(game_day)
    game_day.league&.game_operation&.state_association&.checklist_items&.to_a || []
  end

  # Normalisiert die eingereichten Antworten gegen die Checklisten-Items.
  # nil, wenn nicht jede Frage eindeutig mit true/false beantwortet wurde.
  def normalize_answers(raw, items)
    return nil unless raw.respond_to?(:each)

    by_id = {}
    raw.each do |a|
      id = (a[:item_id] || a['item_id']).to_i
      by_id[id] = a.key?(:answer) ? a[:answer] : a['answer']
    end

    answers = items.map do |item|
      { 'item_id' => item.id, 'question' => item.question, 'answer' => by_id[item.id] }
    end
    return nil unless answers.all? { |a| [true, false].include?(a['answer']) }

    answers
  end

  def confirmation_payload(confirmation)
    {
      team_id: confirmation.team_id,
      confirmed_at: confirmation.confirmed_at.iso8601,
      properly_conducted: confirmation.properly_conducted,
      checklist_answers: confirmation.checklist_answers
    }
  end

  # Benachrichtigt die SBK des LV, wenn eine Gastmannschaft einen Spieltag als
  # nicht ordnungsgemäß gemeldet hat. Fehler hier dürfen die Antwort nicht scheitern lassen.
  def notify_sbk_of_veto(game_day, team, confirmation)
    sa = game_day.league&.game_operation&.state_association
    return if sa&.sbk_email.blank?

    GameDayMailer.team_checklist_veto(game_day, team, confirmation.checklist_answers, sa).deliver_later
  rescue StandardError => e
    Rails.logger.warn("notify_sbk_of_veto(team) failed for game_day_id=#{game_day.id}: #{e.class}: #{e.message}")
  end

  def game_day_json(game_day, teams, day_confirmations)
    items = checklist_items_for(game_day)

    {
      id: game_day.id,
      date: game_day.date,
      league: game_day.league&.name,
      arena: game_day.arena&.name,
      club: game_day.club&.name,
      auto_confirmed: auto_confirmed?(game_day),
      confirmable_from: last_game_start(game_day)&.iso8601,
      # Bestätigung nur nötig, wenn der LV der Liga eine Checkliste hinterlegt hat.
      checklist_required: items.any?,
      checklist_items: items.map { |i| { id: i.id, question: i.question } },
      my_teams: teams.map do |t|
        c = day_confirmations.find { |x| x.team_id == t.id }
        {
          team_id: t.id,
          team_name: t.name,
          confirmed_at: c&.confirmed_at&.iso8601,
          properly_conducted: c&.properly_conducted,
          checklist_answers: c&.checklist_answers || []
        }
      end,
      games: game_day.games
                     .sort_by { |g| g.start_time || '' }
                     .map do |g|
               {
                 id: g.id,
                 game_number: g.game_number,
                 start_time: g.start_time,
                 home_team: g.home_team&.name,
                 guest_team: g.guest_team&.name,
                 result: g.result_string
               }
             end
    }
  end
end
