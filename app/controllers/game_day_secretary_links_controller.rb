class GameDaySecretaryLinksController < ApplicationController
  before_action :authenticate_user
  before_action :load_game_day, only: %i[create show]
  before_action :authorize_vm_or_tm!, only: %i[create show]

  # Zeitfenster der Übersicht: ein paar Tage zurück, damit ein Link während der
  # laufenden 72-Stunden-Gültigkeit noch einmal ausgegeben werden kann, und weit
  # genug nach vorn für die Vorbereitung.
  LIST_PAST_DAYS = 3
  LIST_FUTURE_DAYS = 60

  # GET /api/v2/user/secretary_game_days
  # Spieltage, für die der/die Angemeldete als Vereins- oder Teammanager:in
  # einen Link erzeugen darf, gruppiert nach Halle und Datum.
  #
  # Bewusst nur der VM/TM-Umfang: Admin und SBK dürfen zwar ebenfalls Links
  # erzeugen (siehe authorize_vm_or_tm!), tun das aber über die
  # Spielplan-Verwaltung. Für sie wäre die Liste sonst der halbe Spielplan.
  def index
    groups = hall_day_groups
    return render json: [] if groups.empty?

    links_by_game_day = active_links_by_game_day(groups.values.flatten.map(&:id))

    payload = groups.map do |(arena_id, date), game_days|
      covered = game_days.select { |gd| may_manage_secretary_link?(gd) }
      next if covered.empty?

      hall_day_json(arena_id, date, game_days, covered, links_by_game_day)
    end.compact

    render json: payload.sort_by { |g| g[:date].to_s }
  end

  # POST /api/v2/user/game_days/:game_day_id/secretary_link
  def create
    game_days = coverable_game_days(@game_day)
    link, raw_token = GameDaySecretaryLink.generate!(game_days: game_days, created_by: current_user)

    render json: {
      url: "#{FrontendUrl.base}/spielsekretariat?token=#{raw_token}",
      token: raw_token,
      expires_at: link.expires_at.iso8601,
      created_by: current_user.fullname,
      # game_day_id bleibt der angefragte Spieltag – ältere Frontends lesen ihn.
      game_day_id: @game_day.id,
      game_day_ids: game_days.map(&:id),
      game_days: game_days.map { |gd| game_day_stub(gd) }
    }, status: :created
  end

  # GET /api/v2/user/game_days/:game_day_id/secretary_link
  def show
    link = GameDaySecretaryLink.active.covering([@game_day.id]).order(:created_at).last
    if link
      render json: {
        expires_at: link.expires_at.iso8601,
        created_by: link.created_by&.fullname,
        game_day_ids: link.covered_game_day_ids
      }
    else
      render json: { active: false }
    end
  end

  private

  def load_game_day
    @game_day = GameDay.find(params[:game_day_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Spieltag nicht gefunden.' }, status: :not_found
  end

  def authorize_vm_or_tm!
    return if may_manage_secretary_link?(@game_day)

    render json: { error: 'Nicht berechtigt.' }, status: :forbidden
  end

  # Darf der/die Angemeldete für diesen Spieltag einen Sekretariats-Link
  # erzeugen? Admin und SBK des Spielbetriebs, VM des Ausrichters oder eines
  # beteiligten Vereins, TM einer beteiligten Mannschaft.
  def may_manage_secretary_link?(game_day)
    ph = current_user.permission_hash
    return true if ph[:admin].present?

    go_id = game_day.league&.game_operation_id
    return true if ph[:sbk].present? && (ph[:sbk].include?(0) || ph[:sbk].include?(go_id))

    team_ids = game_day.games.flat_map { |g| [g.home_team_id, g.guest_team_id] }.compact
    return true if ph[:tm].present? && ph[:tm].intersection(team_ids).present?

    return false if ph[:vm].blank?
    return true if ph[:vm].include?(game_day.club_id)

    game_day.games.any? do |g|
      ph[:vm].intersection([g.home_team&.club_id, g.guest_team&.club_id].compact).present?
    end
  end

  # Die Spieltage, die ein Link für `game_day` abdeckt: alle Spieltage derselben
  # Halle am selben Tag, aber nur die, für die der/die Erzeugende berechtigt ist.
  # Ohne diese Prüfung je Spieltag würde eine gemeinsam genutzte Halle einem VM
  # den Spielbericht einer fremden Liga öffnen.
  def coverable_game_days(game_day)
    siblings = game_day.hall_day_siblings
                       .includes(:league, games: %i[home_team guest_team])
                       .to_a
    covered = siblings.select { |gd| may_manage_secretary_link?(gd) }
    covered.presence || [game_day]
  end

  # Spieltage im Zeitfenster, an denen der/die Angemeldete als VM oder TM
  # beteiligt ist, samt aller Spieltage derselben Halle am selben Tag –
  # gruppiert nach [arena_id, date]. Ohne Halle bildet der Spieltag eine
  # eigene Gruppe, damit er nicht aus der Liste fällt.
  def hall_day_groups
    seeds = seed_game_days
    return {} if seeds.empty?

    keyed, unkeyed = seeds.partition { |gd| gd.arena_id.present? && gd.date.present? }
    groups = sibling_game_days(keyed).group_by { |gd| [gd.arena_id, gd.date] }
    unkeyed.each { |gd| groups[[nil, gd.date]] = [gd] }
    groups
  end

  def seed_game_days
    return [] if vm_club_ids.empty? && tm_team_ids.empty?

    scope = GameDay.where(id: hosted_game_day_ids + participating_game_day_ids)
    scope.where("TO_DATE(game_days.date, 'YYYY-MM-DD') BETWEEN ? AND ?",
                LIST_PAST_DAYS.days.ago.to_date, LIST_FUTURE_DAYS.days.from_now.to_date)
         .to_a
  end

  def hosted_game_day_ids
    return [] if vm_club_ids.empty?

    GameDay.where(club_id: vm_club_ids).pluck(:id)
  end

  def participating_game_day_ids
    team_ids = tm_team_ids
    team_ids += Team.where(club_id: vm_club_ids).pluck(:id) if vm_club_ids.present?
    return [] if team_ids.empty?

    GameDay.joins(:games)
           .where('games.home_team_id IN (:t) OR games.guest_team_id IN (:t)', t: team_ids.uniq)
           .distinct
           .pluck(:id)
  end

  def sibling_game_days(game_days)
    pairs = game_days.map { |gd| [gd.arena_id, gd.date] }.uniq
    condition = Array.new(pairs.size, '(arena_id = ? AND date = ?)').join(' OR ')
    GameDay.where(condition, *pairs.flatten)
           .includes(:arena, :league, games: %i[home_team guest_team])
           .to_a
  end

  def vm_club_ids
    @vm_club_ids ||= Array(current_user.permission_hash[:vm]).map(&:to_i)
  end

  def tm_team_ids
    @tm_team_ids ||= Array(current_user.permission_hash[:tm]).map(&:to_i)
  end

  # Aktive Links je Spieltag. Deckt ein Link mehrere Spieltage ab, taucht er
  # unter jedem auf; je Spieltag gewinnt der zuletzt erzeugte.
  def active_links_by_game_day(game_day_ids)
    GameDaySecretaryLink.active
                        .covering(game_day_ids)
                        .includes(:created_by, :game_day_secretary_link_game_days)
                        .order(:created_at)
                        .each_with_object({}) do |link, hash|
      link.covered_game_day_ids.each { |id| hash[id] = link }
    end
  end

  def hall_day_json(arena_id, date, game_days, covered, links_by_game_day)
    arena = game_days.first&.arena
    link = covered.filter_map { |gd| links_by_game_day[gd.id] }.max_by(&:created_at)

    {
      arena_id: arena_id,
      arena: arena&.name,
      arena_city: arena&.city,
      date: date,
      # Ein Link deckt nur die Spieltage ab, für die der/die Angemeldete
      # berechtigt ist. Weicht das von den Spieltagen der Halle ab, soll das
      # Frontend es benennen können statt stillschweigend weniger zu liefern.
      game_days: covered.map { |gd| game_day_stub(gd) },
      other_game_days_in_hall: (game_days - covered).map { |gd| game_day_stub(gd) },
      link: link && {
        expires_at: link.expires_at.iso8601,
        created_by: link.created_by&.fullname,
        game_day_ids: link.covered_game_day_ids
      }
    }
  end

  def game_day_stub(game_day)
    {
      id: game_day.id,
      number: game_day.number,
      date: game_day.date,
      league: game_day.league&.name,
      league_id: game_day.league_id,
      games_count: game_day.games.size
    }
  end
end
