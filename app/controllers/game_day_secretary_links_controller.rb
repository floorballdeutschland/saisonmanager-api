class GameDaySecretaryLinksController < ApplicationController
  include GameDayLinkAuthorization

  before_action :authenticate_user
  before_action :load_game_day, only: %i[create show]
  before_action :authorize_vm_or_tm!, only: %i[create show]

  # Zeitfenster der Übersicht: ein paar Tage zurück, damit ein Link während
  # seiner Gültigkeit (GameDaySecretaryLink::VALIDITY, 72 Stunden) noch einmal
  # ausgegeben werden kann, und weit genug nach vorn für die Vorbereitung.
  # Wird VALIDITY verlängert, gehört dieser Wert mit angehoben.
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

    payload = groups.map do |(arena_id, date, _standalone_id), game_days|
      covered = game_days.select { |gd| may_manage_game_day_link?(gd) }
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
      # Der angefragte Spieltag, für Abwärtskompatibilität erhalten. Welche
      # Spieltage der Link wirklich abdeckt, steht in game_day_ids.
      game_day_id: @game_day.id,
      game_day_ids: game_days.map(&:id),
      game_days: game_days.map { |gd| game_day_stub(gd) }
    }, status: :created
  rescue ArgumentError
    # coverable_game_days kann nur leer werden, wenn der Spieltag zwischen
    # Rechteprüfung und Auswahl seine Spiele verliert (die TM-Berechtigung hängt
    # daran). Selten, aber ein 500 wäre die falsche Antwort darauf.
    render json: { error: 'Für diesen Spieltag gibt es nichts mehr zu vergeben.' },
           status: :unprocessable_entity
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

  def authorize_vm_or_tm!
    return if may_manage_game_day_link?(@game_day)

    render json: { error: 'Nicht berechtigt.' }, status: :forbidden
  end

  # Die Spieltage, die ein Link für `game_day` abdeckt: alle Spieltage derselben
  # Halle am selben Tag, aber nur die, für die der/die Erzeugende berechtigt ist.
  # Ohne diese Prüfung je Spieltag würde eine gemeinsam genutzte Halle einem VM
  # den Spielbericht einer fremden Liga öffnen.
  #
  # `@game_day` ist immer dabei: authorize_vm_or_tm! hat dafür schon bestätigt,
  # und hall_day_siblings enthält self in jedem Zweig.
  def coverable_game_days(game_day)
    game_day.hall_day_siblings
            .includes(:league, games: %i[home_team guest_team])
            .select { |gd| may_manage_game_day_link?(gd) }
  end

  # Spieltage im Zeitfenster, an denen der/die Angemeldete als VM oder TM
  # beteiligt ist, samt aller Spieltage derselben Halle am selben Tag –
  # gruppiert nach [arena_id, date, ohne-Halle-Kennung].
  #
  # Spieltage ohne Halle oder ohne verwertbares Datum lassen sich nicht
  # zusammenfassen und bilden je eine eigene Gruppe. Die Spieltag-ID gehört
  # deshalb in den Schlüssel: sonst überschrieben sich zwei solche Spieltage
  # desselben Tages gegenseitig und einer verschwände stumm aus der Übersicht.
  def hall_day_groups
    seeds = seed_game_days
    return {} if seeds.empty?

    keyed, unkeyed = seeds.partition { |gd| gd.arena_id.present? && gd.date.present? }
    groups = sibling_game_days(keyed).group_by { |gd| [gd.arena_id, gd.date, nil] }
    unkeyed.each { |gd| groups[[nil, gd.date, gd.id]] = [gd] }
    groups
  end

  # `game_days.date` ist Text. Ein leerer Wert ergibt in TO_DATE eine Datumsangabe
  # vor Christus und fällt damit lautlos aus dem Zeitfenster; alles andere
  # Unpassende (etwa „TBD" oder ein 30. Februar) lässt TO_DATE werfen und reißt
  # die ganze Übersicht mit in einen 500er. Beides ist hier schlecht: Diese Seite
  # ist der einzige Weg des Vereins zum Link.
  #
  # Deshalb erst das Format prüfen und nur wohlgeformte Datumsangaben durch das
  # Fenster schicken. Der Rest kommt durch und landet in der eigenen Gruppe, die
  # hall_day_groups für nicht gruppierbare Spieltage vorsieht.
  DATE_PATTERN = '^\d{4}-\d{2}-\d{2}$'.freeze

  def seed_game_days
    return [] if vm_club_ids.empty? && tm_team_ids.empty?

    GameDay.where(id: hosted_game_day_ids + participating_game_day_ids)
           .where(
             'game_days.date IS NULL ' \
             "OR game_days.date !~ :pattern " \
             "OR TO_DATE(game_days.date, 'YYYY-MM-DD') BETWEEN :from AND :to",
             pattern: DATE_PATTERN,
             from: LIST_PAST_DAYS.days.ago.to_date,
             to: LIST_FUTURE_DAYS.days.from_now.to_date
           )
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
    # Ohne diesen Ausstieg entstünde `where('')`, und das trifft jede Zeile der
    # Tabelle – die Übersicht bekäme dann den kompletten Spielplan vorgelegt.
    return [] if pairs.empty?

    condition = Array.new(pairs.size, '(arena_id = ? AND date = ?)').join(' OR ')
    GameDay.where(condition, *pairs.flatten)
           .includes(:arena, :league, games: %i[home_team guest_team])
           .to_a
  end

  def vm_club_ids
    @vm_club_ids ||= Array(permissions[:vm]).map(&:to_i)
  end

  def tm_team_ids
    @tm_team_ids ||= Array(permissions[:tm]).map(&:to_i)
  end

  # Aktive Links je Spieltag. Deckt ein Link mehrere Spieltage ab, taucht er
  # unter jedem auf; je Spieltag gewinnt der zuletzt erzeugte. Nach
  # revoke_coverage_of sollte es je Spieltag ohnehin nur einen geben, die
  # Tie-Break-Regel ist reine Absicherung.
  #
  # `covering` filtert per joins auf die Zuordnungstabelle, `includes` lädt sie
  # getrennt nach – deshalb sieht covered_game_day_ids alle Spieltage. Käme hier
  # ein `references` dazu, würde daraus ein eager_load mit der Filterbedingung,
  # und die Methode lieferte nur noch den gefilterten Ausschnitt.
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
    # Nur lesen, wenn über die Halle gruppiert wurde. Ein Spieltag ohne
    # verwertbares Datum landet mit arena_id nil in einer eigenen Gruppe, hätte
    # aber sehr wohl eine Halle – Name ohne ID widerspräche der Zusage, die das
    # Frontend als Union typisiert (beides gesetzt oder keines).
    arena = arena_id && game_days.first&.arena
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
