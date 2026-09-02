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

    all_ids = groups.values.flatten.map(&:id)
    links_by_game_day = active_links_by_game_day(all_ids)
    overlays_by_game_day = active_overlay_links_by_game_day(all_ids)

    payload = groups.map do |(arena_id, date, _standalone_id), game_days|
      covered = game_days.select { |gd| may_manage_game_day_link?(gd) }
      next if covered.empty?

      hall_day_json(arena_id, date, game_days, covered, links_by_game_day, overlays_by_game_day)
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
    # coverable_game_days wird leer, wenn dem Spieltag zwischen Rechteprüfung
    # und Auswahl die Grundlage der eigenen Berechtigung abhandenkommt: der
    # Ausrichter (VM) oder die eigenen Spiele (TM). In der Spielplan-Verwaltung
    # ist beides ein normaler Vorgang. Selten, aber ein 500 wäre die falsche
    # Antwort darauf.
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

  # Spieltage im Zeitfenster, die ein Verein des/der Angemeldeten ausrichtet,
  # samt aller Spieltage derselben Halle am selben Tag – gruppiert nach
  # [arena_id, date, ohne-Halle-Kennung].
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
    load_with_games(unkeyed).each { |gd| groups[[nil, gd.date, gd.id]] = [gd] }
    groups
  end

  # Die nicht gruppierbaren Spieltage gehen ohne den Umweg über
  # sibling_game_days direkt in die Rechteprüfung. Ihre Spiele, Ligen und
  # Mannschaften gehören deshalb hier geladen: `own_teams` fasst zu jedem Spiel
  # beide Mannschaften als Objekt an, und einzeln nachgeladen sind das zwei
  # Abfragen je Spiel. Gemessen bei vier Spieltagen mit je drei Spielen: 41
  # Abfragen statt 17, und der Abstand wächst mit jedem Spieltag.
  def load_with_games(game_days)
    return [] if game_days.empty?

    GameDay.where(id: game_days.map(&:id))
           .includes(:league, games: %i[home_team guest_team])
           .to_a
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
    ids = candidate_game_day_ids
    return [] if ids.empty?

    GameDay.where(id: ids)
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

  # Nur Spieltage des ausrichtenden Vereins – die Auswärtsspieltage einer
  # eigenen Mannschaft gehören bewusst nicht mehr dazu (Anlass api#551). Am
  # Tisch sitzt der Ausrichter; die Übersicht soll nicht mehr zeigen, als sich
  # vergeben lässt.
  #
  # Nach außen ändert die Vorauswahl nichts: `index` prüft ohnehin je Spieltag
  # nach und lässt eine Gruppe ohne berechtigten Spieltag ganz weg. Sie spart
  # Arbeit, keine Ergebnisse – deshalb hängt an ihr auch kein eigener Test außer
  # dem für die Spielgemeinschaft, wo `all_club_ids` sehr wohl sichtbar wird.
  #
  # Für den Teammanager ist das der Verein seiner Mannschaft(en). Ob dieser
  # Spieltag dann wirklich eine seiner Mannschaften enthält, entscheidet
  # may_manage_game_day_link? je Spieltag – hier wird nur vorausgewählt.
  def candidate_game_day_ids
    club_ids = (vm_club_ids + tm_team_club_ids).uniq
    return [] if club_ids.empty?

    GameDay.where(club_id: club_ids).pluck(:id)
  end

  # `all_club_ids` statt `club_id`: Eine Spielgemeinschaft richtet auch unter
  # ihrem Partnerverein aus, und dann steht dessen ID am Spieltag.
  def tm_team_club_ids
    return [] if tm_team_ids.empty?

    Team.where(id: tm_team_ids).flat_map(&:all_club_ids).compact.uniq
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

  # Aktive Overlay-Zugänge je Spieltag. Anders als der Sekretariatslink gilt ein
  # Overlay-Token für genau einen Spieltag (GameDayOverlayLink), deshalb hier
  # keine Zuordnungstabelle.
  #
  # `order(:created_at)` trotz des eindeutigen Index aus
  # 20260902110000: `index_by` behält bei gleichem Schlüssel den zuletzt
  # gelesenen Eintrag, und wenn diese Reihenfolge doch einmal etwas entscheidet,
  # soll es der zuletzt erzeugte Zugang sein. Dieselbe Absicherung wie oben beim
  # Sekretariatslink, aus demselben Grund: Eine falsche Auskunft darüber, wem
  # ein Zugang gehört, ist schlimmer als gar keine.
  def active_overlay_links_by_game_day(game_day_ids)
    GameDayOverlayLink.active
                      .where(game_day_id: game_day_ids)
                      .includes(:created_by)
                      .order(:created_at)
                      .index_by(&:game_day_id)
  end

  def hall_day_json(arena_id, date, game_days, covered, links_by_game_day, overlays_by_game_day)
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
      game_days: covered.map { |gd| game_day_stub(gd).merge(overlay_link: overlay_link_json(overlays_by_game_day[gd.id])) },
      other_game_days_in_hall: (game_days - covered).map { |gd| game_day_stub(gd) },
      link: link && {
        expires_at: link.expires_at.iso8601,
        created_by: link.created_by&.fullname,
        game_day_ids: link.covered_game_day_ids
      }
    }
  end

  # Nur der Zustand, nie das Token: Der Klartext existiert einmalig in der
  # Antwort auf GameDayOverlayLinksController#create.
  #
  # Steht bewusst nur an den eigenen Spieltagen (`covered`), nicht an
  # `other_game_days_in_hall`: Wer für einen Spieltag keinen Zugang vergeben
  # darf, braucht auch den Namen dessen nicht zu erfahren, der ihn vergeben hat.
  def overlay_link_json(link)
    return nil if link.nil?

    {
      active: true,
      expires_at: link.expires_at.iso8601,
      created_by: link.created_by&.fullname
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
