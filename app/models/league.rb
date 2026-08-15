class League < ApplicationRecord
  include UserTrackable
  include LeagueDirectEncounterTable
  include LeagueBanner
  include LeagueLogo
  include LeagueRefereeAssignment

  has_many :game_days
  has_many :qualifications, class_name: 'LeagueQualification',
                            foreign_key: :source_league_id, dependent: :destroy
  belongs_to :game_operation

  # Kanonische Ligaklassen-Codes des Liga-Formulars (Reihenfolge = Rang, siehe
  # CLASS_RANKS). Der Datenbestand kennt seit der Normalisierungs-Migration
  # (#297) nur noch diese Codes bzw. leer (''/NULL).
  CODES = %w[1fbl 2fbl rl vl ll].freeze

  validates :name, presence: true
  validates :season_id, presence: true
  validates :league_class_id, inclusion: { in: CODES }, allow_blank: true

  default_scope { order(:season_id, :game_operation_id).order('order_key::int') }
  scope :current_season, -> { where(season_id: Setting.current_season_id) }

  # Lädt alles vor, was League#full_hash pro Liga liest. Für Listen-Endpunkte
  # (GameOperations#index_leagues, similar_leagues in Leagues#show) Pflicht,
  # sonst ~8 Queries pro Liga (Sentry-N+1: game_operation, game_days ×2,
  # qualifications + target_league, Banner-Attachments, state_association).
  # Achtung: pluck und .order umgehen Preloading – game_day_numbers und
  # full_hash prüfen deshalb auf loaded?.
  scope :with_full_hash_includes, lambda {
    includes(:game_days,
             { qualifications: :target_league },
             { banner_attachment: :blob },
             { logo_attachment: :blob },
             game_operation: { banner_attachment: :blob,
                               state_association: { banner_attachment: :blob,
                                                    logo_attachment: :blob } })
  }

  # Die kleine Schwester für Listen, die full_hash je Liga aufrufen, ohne
  # Spieltage und Qualifikationen zu brauchen. Entscheidend sind die beiden
  # Ketten hinter resolved_banner und resolved_logo: Ohne sie fragt jede Liga
  # einzeln nach Spielbetrieb, Landesverband und deren Anhängen, und aus einer
  # Ligenliste werden schnell ein paar hundert Abfragen.
  scope :with_resolved_media_includes, lambda {
    includes({ banner_attachment: :blob },
             { logo_attachment: :blob },
             game_operation: { banner_attachment: :blob,
                               state_association: { banner_attachment: :blob,
                                                    logo_attachment: :blob } })
  }

  # Kanonische Ligaklassen-Codes mit Rang für die Haupt-/Zusatzlizenz-
  # Bestimmung (license_type; kleinerer Rang = höhere Liga). Seit der Normalisierungs-Migration (#297)
  # enthält der Datenbestand (leagues.league_class_id und die Kopien in
  # players.licenses) nur noch diese Codes bzw. leer (''/NULL) für Wettbewerbe
  # ohne Ligaklasse (DM, Pokal, Trophy). Vorwärts sichern das die Inclusion-
  # Validierung unten (Ligen) und das Kopieren von league_class_id bei der
  # Lizenzanlage (players_controller).
  CLASS_RANKS = { '1fbl' => 1, '2fbl' => 2, 'rl' => 3, 'vl' => 4, 'll' => 5 }.freeze
  # Sentinel-Rang für unbekannte/leere Klassen: sortiert ans Ende
  # (= niedrigste Liga). Bewusst ein großer Integer statt Float::INFINITY, damit
  # der Wert JSON-serialisierbar bleibt (er landet via 'sorting' im Response).
  UNKNOWN_CLASS_RANK = 999_999

  def self.class_rank(league_class_id)
    CLASS_RANKS.fetch(league_class_id.to_s.strip, UNKNOWN_CLASS_RANK)
  end

  # Namensmuster + Wert-Mapping zur Normalisierung von league_class_id auf die
  # kanonischen Codes (portiert aus Migration #297). Nötig, weil Altbestände /
  # Legacy-Importe un-normalisierte Werte (z. B. "10") tragen können, die per
  # update_columns/Raw-SQL an der Inclusion-Validierung vorbei geschrieben
  # wurden. Ohne Normalisierung bricht z. B. das Liga-Kopieren mit
  # "League class is not included in the list" ab (#114).
  CLASS_NAME_PATTERNS = [
    [/(?<![a-zäöü])deutsche meisterschaft/i, ''],
    [/1\.\s*(floorball[\s-]*)?(bundesliga|fbl)/i, '1fbl'],
    [/2\.\s*(floorball[\s-]*)?(bundesliga|fbl)/i, '2fbl'],
    [/regionalliga/i, 'rl'],
    [/verbandsliga/i, 'vl'],
    [/landesliga/i, 'll']
  ].freeze

  CLASS_VALUE_MAP = {
    '1' => '1fbl', '10' => '1fbl',
    '20' => '2fbl',
    '30' => 'rl', '240' => 'rl', '250' => 'rl', '270' => 'rl', '280' => 'rl',
    '290' => 'rl', '300' => 'rl', '310' => 'rl', '320' => 'rl', '340' => 'rl',
    '40' => 'vl', '330' => 'vl',
    '50' => 'll'
  }.freeze

  # Bildet einen beliebigen league_class_id-Wert auf einen der CODES oder ''
  # ab. Bereits kanonische Werte und Leerwerte bleiben unverändert; sonst
  # gewinnt das Namensmuster (z. B. "1. FBL Damen" => 1fbl) vor dem
  # Wert-Mapping, unbekannte Werte werden zu '' (keine Ligaklasse).
  def self.normalize_class_id(value, name = nil)
    v = value.to_s.strip
    return v if v.blank? || CODES.include?(v)

    CLASS_NAME_PATTERNS.each { |pattern, code| return code if name.to_s.match?(pattern) }
    CLASS_VALUE_MAP.fetch(v, '')
  end

  # Großfeld-Erwachsenenbereich: nur hier gibt es die Erst-/Zweitlizenz-
  # Zuordnung. Jugendligen tragen ein age_group wie "U17 Junioren" –
  # Erwachsenen-Ligen haben age_group leer oder z. B. "Herren"/"Damen"/"Ü30".
  def gf_adult?
    field_size == 'GF' && !age_group.to_s.match?(/\AU\d/)
  end

  # Mannschaft samt Verein und beiden Logo-Anhängen. schedule_item liest pro
  # Spiel logo_url_fallback und logo_small_url_fallback beider Mannschaften;
  # beide fragen `logo.attached?` und fallen bei fehlendem Team-Logo auf das
  # Vereinslogo zurück. Ohne die Attachment-Preloads holt ActiveStorage jeden
  # Anhang einzeln nach – gemessen im Juli 2026 der häufigste N+1 überhaupt,
  # rund 71.000 Ereignisse auf #schedule und #current_schedule.
  #
  # Auch für die Tabelle, die dieselben beiden Methoden je Team liest
  # (evaluate_table_results/empty_table_item).
  TEAM_WITH_LOGO_PRELOAD = [
    { logo_attachment: :blob },
    { club: { logo_attachment: :blob } }
  ].freeze

  def games(game_day_number = nil)
    gd = game_day_number.present? ? game_days.where(number: game_day_number) : game_days
    # :club zusätzlich, weil schedule_item game_day.hosting_club (= club.name)
    # liest – sonst eine Club-Query pro Spieltag.
    gd.includes(:arena, :club,
                games: [{ home_team: TEAM_WITH_LOGO_PRELOAD },
                        { guest_team: TEAM_WITH_LOGO_PRELOAD }])
      .map(&:games).flatten.sort_by { |i| i.game_number.to_i }
  end

  def teams
    Team.where(league_id: id).or(Team.where('? = ANY (cup_leagues)', id))
  end

  def similar_leagues
    League.where(season_id:, league_system_id:,
                 league_class_id:).where.not(id:)
  end

  def forfait_goals
    return 5 if legacy_league && [1, 4, 102].include?(league_category_id.to_i) # GF, Pokal GF, GF DM
    return 8 if legacy_league

    return 5 if field_size == 'GF'

    8
  end

  # Spielt diese Liga über drei Drittel (Großfeld) statt über zwei Hälften?
  # Gemeinsame Quelle von period_titles und period_count_normal_game, damit die
  # beiden nicht auseinanderlaufen.
  #
  # Altligen entscheiden über `league_category_id`, weil der Legacy-Import
  # `periods` nie schreibt. Neue Ligen pflegen `periods`, dort bleibt
  # `league_category_id` leer; fehlt `periods`, gilt Hälften.
  #
  # Ausnahme sind kopierte Altligen (Leagues#admin_copy): die tragen
  # legacy_league=false, bringen die alte Kategorie aber mit und haben oft kein
  # `periods`. Sie zählen deshalb Hälften, so wie es das Formular über
  # period_titles ohnehin schon anbietet.
  def thirds?
    return [1, 4, 102].include?(league_category_id.to_i) if legacy_league # GF, Pokal GF, GF DM

    periods == 3
  end

  def period_count_normal_game
    thirds? ? 3 : 2
  end

  def period_overtime
    period_count_normal_game + 1
  end

  def period_penalty_shots
    period_overtime + 1
  end

  # Die Abschnitte eines Spiels in Reihenfolge. Spielabschnitte tragen ganze
  # Nummern, Pausen die halbe Nummer nach dem Abschnitt davor (Pause nach
  # Abschnitt 2 also 2.5). Nur so passt die Nummerierung zur Reihenfolge in der
  # Liste, aus der das Formular den nächsten Abschnitt bestimmt.
  def period_titles
    if thirds?
      [
        { period: 1, short_title: '1', title: '1. Drittel', status_id: 'period1', can_end_game: false, optional: false,
          running: true },
        { period: 1.5, short_title: 'P1', title: '1. Drittelpause', status_id: 'pause1', can_end_game: false,
          optional: false, running: false },
        { period: 2, short_title: '2', title: '2. Drittel', status_id: 'period2', can_end_game: false, optional: false,
          running: true },
        { period: 2.5, short_title: 'P2', title: '2. Drittelpause', status_id: 'pause2', can_end_game: false,
          optional: false, running: false },
        { period: 3, short_title: '3', title: '3. Drittel', status_id: 'period3', can_end_game: true, optional: false,
          running: true },
        { period: 3.5, short_title: 'PV', title: 'Pause vor Verlängerung', status_id: 'pause_et', can_end_game: false,
          optional: true, running: false },
        { period: 4, short_title: 'V', title: 'Verlängerung', status_id: 'extratime', can_end_game: true,
          optional: true, running: true },
        { period: 4.5, short_title: 'PP', title: 'Pause vor Penalty-Schießen', status_id: 'pause_ps',
          can_end_game: false, optional: true, running: false },
        { period: 5, short_title: 'P', title: 'Penalty-Schießen', status_id: 'penalty_shots', can_end_game: true,
          optional: true, running: true }
      ]
    else
      [
        { period: 1, short_title: '1', title: '1. Hälfte', status_id: 'period1', can_end_game: false, optional: false,
          running: true },
        { period: 1.5, short_title: 'HZ', title: 'Halbzeitpause', status_id: 'pause1', can_end_game: false,
          optional: false, running: false },
        { period: 2, short_title: '2', title: '2. Hälfte', status_id: 'period2', can_end_game: true, optional: false,
          running: true },
        { period: 2.5, short_title: 'PV', title: 'Pause vor Verlängerung', status_id: 'pause_et', can_end_game: false,
          optional: true, running: false },
        { period: 3, short_title: 'V', title: 'Verlängerung', status_id: 'extratime', can_end_game: true,
          optional: true, running: true },
        { period: 3.5, short_title: 'PP', title: 'Pause vor Penalty-Schießen', status_id: 'pause_ps',
          can_end_game: false, optional: true, running: false },
        { period: 4, short_title: 'P', title: 'Penalty-Schießen', status_id: 'penalty_shots', can_end_game: true,
          optional: true, running: true }
      ]
    end
  end

  def period_title_by_id(status_id)
    period_titles.select { |pt| pt[:status_id] == status_id }.first
  end

  # Perioden-basierter Fallback für die angenommene Spieldauer, wenn weder an der
  # Liga noch global etwas gepflegt ist (entspricht dem bisherigen iCal-Verhalten:
  # Großfeld 2 h, sonst 1 h).
  FALLBACK_GAME_DURATION_MINUTES = 60
  LARGE_FIELD_GAME_DURATION_MINUTES = 120

  # Angenommene Spieldauer (inkl. Puffer) in Minuten für die Hallenbelegungs-/
  # Konfliktprüfung. Reihenfolge: Liga-Override → globaler Default → Fallback.
  def effective_game_duration_minutes
    return game_duration_minutes if game_duration_minutes.present?

    global_default = Setting.default_game_duration_minutes
    return global_default if global_default.present?

    periods.to_i > 2 ? LARGE_FIELD_GAME_DURATION_MINUTES : FALLBACK_GAME_DURATION_MINUTES
  end

  # Erfüllt das Geburtsdatum die Altersvoraussetzung (Stichtag) der Liga?
  # before_deadline: true = "geboren bis" (<= Stichtag), false = "geboren ab" (>= Stichtag).
  # Ohne Stichtag oder bei fehlendem/unlesbarem Geburtsdatum keine Sperre.
  def age_eligible?(birthdate)
    return true if deadline.blank? || birthdate.blank?

    dob = birthdate.is_a?(Date) ? birthdate : Date.parse(birthdate.to_s)
    before_deadline ? dob <= deadline : dob >= deadline
  rescue ArgumentError, TypeError
    true
  end

  def full_hash(include_similar_leagues = false)
    result = {
      id:,
      game_operation_id:,
      game_operation_name: game_operation.name,
      game_operation_short_name: game_operation.short_name,
      game_operation_slug: game_operation.slug,
      league_category_id:,
      league_class_id:,
      # Eingefrorene Anzeige-Namen (beim Anlegen aus Setting übernommen), damit
      # eine spätere Umbenennung in Setting alte Ligen nicht rückwirkend ändert.
      league_class_name:,
      league_category_name:,
      league_system_id:,
      league_type:, # legacy!
      name:,
      female:,
      age_group:,
      enable_scorer:,
      short_name:,
      season_id:,
      order_key:,
      game_day_numbers:,
      game_day_titles:,

      deadline:,
      before_deadline:,
      parental_consent_required:,
      referee_feedback_enabled:,

      legacy_league:,
      field_size:,
      league_modus:,
      has_preround:,

      league_id_direct_encounters:,
      league_id_preround:,
      preround_point_modus:,
      # league_id_preseason: league_id_preseason,
      # preround_scorer_modus: preround_scorer_modus,
      table_modus:,
      direct_comparison:,
      periods:,
      period_length:,
      overtime_length:,
      game_duration_minutes:,
      required_documents: required_documents || [],
      qualifications: sorted_qualifications.map do |q|
        {
          id: q.id,
          rank_from: q.rank_from,
          rank_to: q.rank_to,
          qualification_type: q.qualification_type,
          label: q.label,
          target_league_id: q.target_league_id,
          target_league_name: q.target_league&.name
        }
      end
    }
    result.merge!(resolved_banner)
    result.merge!(resolved_logo)
    result[:similar_leagues] = similar_leagues.with_full_hash_includes.map(&:full_hash) if include_similar_leagues

    result
  end

  # rank_from ist NOT NULL; vorgeladene Qualifikationen in Ruby sortieren,
  # statt mit .order das Preloading zu umgehen (eine Extra-Query pro Liga).
  def sorted_qualifications
    qualifications.loaded? ? qualifications.sort_by(&:rank_from) : qualifications.order(:rank_from)
  end

  def hash_with_teams
    hash = full_hash

    hash[:teams] = teams.map(&:full_hash)

    hash
  end

  def league_category
    'league_category'
  end

  def league_class
    'league_class'
  end

  def league_system
    'league_system'
  end

  def league_type
    if legacy_league
      return 'league' if [1, 2, 5].include? league_category_id.to_i
      return 'cup' if [3, 4].include? league_category_id.to_i
      return 'champ' if league_category_id.to_i >= 100
    else
      league_modus
    end
  end

  # loaded?-Check: pluck würde vorgeladene game_days ignorieren und pro Liga
  # neu queryen (full_hash ruft das via game_day_numbers UND game_day_titles
  # doppelt auf).
  def game_day_numbers
    numbers = game_days.loaded? ? game_days.map(&:number) : game_days.pluck(:number)
    numbers.uniq.sort
  end

  # Landesverband, dessen Einstellungen für diese Liga gelten: der LV des
  # Spielbetriebs, dem die Liga gehört. Nicht der LV eines beteiligten Vereins.
  # Die Zuständigkeit folgt der Liga, nicht der Vereinszugehörigkeit.
  def state_association
    game_operation&.state_association
  end

  # Darf in dieser Liga eine Expresslizenz beantragt werden? Erlaubnis und
  # Zeitfenster gehören zusammen und stammen beide aus der Liga: der Schalter vom
  # LV ihres Spielbetriebs, das Fenster von ihrem ersten Spieltag. Vorher kam der
  # Schalter vom LV des Vereins, sodass bei einer Mannschaft in mehreren Ligen die
  # Erlaubnis des einen Verbands mit dem Fenster einer fremden Liga kombinierbar war.
  def express_license_possible?(today: Date.current)
    state_association&.effective_express_license_enabled.present? &&
      express_license_window_open?(today:)
  end

  # Erster Spieltag dieser Liga; Referenzpunkt für das Expresslizenz-Fenster.
  #
  # game_days.date ist eine Textspalte: `to_date` wirft bei einem unplausiblen
  # Eintrag Date::Error, und `try` fängt das nicht ab (es schützt nur vor nil).
  # Ein einzelnes krummes Datum hätte damit die Expresslizenz-Prüfung zum
  # Serverfehler gemacht. Gleiche Behandlung wie in current_schedule: solche
  # Einträge zählen einfach nicht mit.
  def first_game_day_date
    game_days.pluck(:date).filter_map do |d|
      d.try(:to_date)
    rescue Date::Error
      nil
    end.min
  end

  def express_license_window_open?(today: Date.current, days: 3)
    d = first_game_day_date
    return false unless d

    (d - today).to_i <= days
  end

  def schedule
    games.map(&:schedule_item).sort_by { |game| schedule_sort_key(game) }
  end

  def game_day_schedule(game_day_number)
    games(game_day_number).map(&:schedule_item).sort_by { |game| schedule_sort_key(game) }
  end

  def current_schedule
    today = Time.zone.today
    game_day_distance = {}
    game_day_numbers.each do |gdn|
      dates = game_days.where(number: gdn).pluck(:date).filter_map do |d|
        d.try(:to_date)
      rescue Date::Error
        nil
      end
      next if dates.empty?

      date_diffs = dates.map { |d| (d - today).to_i.abs }
      game_day_distance[date_diffs.sum(0.0) / date_diffs.size] = gdn
    end

    game_day_number = begin
      game_day_distance[game_day_distance.keys.min]
    rescue StandardError
      game_days.pluck(:number).max
    end
    # Explizit dieselbe Ordnung wie schedule/game_day_schedule, statt die von
    # League#games (nach Spielnummer) zu übernehmen: Diese Antwort und die des
    # Weiter-Zurück-Endpunkts stehen nebeneinander in derselben Ansicht.
    games(game_day_number).map(&:schedule_item).sort_by { |game| schedule_sort_key(game) }
  end

  def meta_item
    attributes.select { |key, _value| %w[name short_name order_key].include?(key) }
  end

  def won_points
    if legacy_league
      league_system_id.to_i == 1 ? 3 : 2
    else
      case table_modus
      when 'classic'
        3
      else
        10
      end
    end
  end

  def draw_points
    if legacy_league
      league_system_id.to_i == 1 ? 1 : 0
    else
      case table_modus
      when 'classic'
        1
      else
        1
      end
    end
  end

  def won_overtime_points
    if legacy_league
      league_system_id.to_i == 1 ? 2 : 0
    else
      case table_modus
      when 'classic'
        2
      else
        0
      end
    end
  end

  def lost_overtime_points
    draw_points
  end

  def scorer
    results = evaluate_scorer
    last_entry = nil
    sorted_results = results.values.sort_by do |player_result|
      [-(player_result[:goals] + player_result[:assists]), -player_result[:goals], -player_result[:games]]
    end
    sorted_results.reject! do |player_result|
      (player_result.slice(:goals, :assists, :penalty_2, :penalty_2and2, :penalty_5, :penalty_10, :penalty_ms_tech, :penalty_ms_full, :penalty_ms1, :penalty_ms2, :penalty_ms3).values.sum - player_result[:games] - player_result[:player_id]).zero? # no goals or penalties.
    end

    player_ids = sorted_results.map { |sr| sr[:player_id] }
    # Namen stammen aus dem Spielbericht-Snapshot (players-JSONB) und sind damit
    # self-contained für Altsaisons. Fehlt der Spieler-Datensatz, bleibt der
    # Scorer trotzdem erhalten (kein stiller Wegfall). Nur wenn der Snapshot
    # keinen Namen trägt (sehr alte Importe), greift der Name aus dem
    # Player-Datensatz als Fallback.
    #
    # Spielerfotos liefert die Scorerliste bewusst nicht: Der Endpunkt ist per
    # X-Api-Key erreichbar, ein Porträt gehört nicht auf die offene Fläche.
    player_lookup = Player.where(id: player_ids).index_by(&:id)

    next_position_diff = 1
    sorted_results.each_with_index do |player_result, index|
      player = player_lookup[player_result[:player_id]]
      player_result[:first_name] = player_result[:first_name].presence || player&.first_name
      player_result[:last_name] = player_result[:last_name].presence || player&.last_name
      player_result[:sort] = index
      if last_entry.nil?
        player_result[:position] = 1
      elsif (player_result[:goals] == last_entry[:goals]) &&
            (player_result[:assists] == last_entry[:assists])
        player_result[:position] = last_entry[:position]
        next_position_diff += 1
      else
        player_result[:position] = last_entry[:position] + next_position_diff
        next_position_diff = 1
      end

      last_entry = player_result
    end

    sorted_results.compact
  end

  def table
    g = games
    results = evaluate_table_results(g)

    apply_direct_encounter_games!(results) if league_id_direct_encounters.present?
    apply_preround_points!(results) if league_id_preround.present? && preround_point_modus.present?

    sorted_results = if direct_comparison
                       sort_by_direct_comparison(results.values, g)
                     else
                       results.values.sort_by do |r|
                         [-r[:points], -r[:goals_diff], -r[:goals_scored]]
                       end
                     end

    last_entry = nil
    next_position_diff = 1
    sorted_results.each_with_index do |team_result, index|
      team_result[:sort] = index
      if last_entry.nil?
        team_result[:position] = 1
      elsif (team_result[:points] == last_entry[:points]) &&
            (team_result[:goals_diff] == last_entry[:goals_diff]) &&
            (team_result[:goals_scored] == last_entry[:goals_scored])
        team_result[:position] = last_entry[:position]
        next_position_diff += 1
      else
        team_result[:position] = last_entry[:position] + next_position_diff
        next_position_diff = 1
      end

      last_entry = team_result
    end

    annotate_with_qualifications!(sorted_results)

    sorted_results
  end

  def grouped_table
    all_games = games
    groups = all_games.map(&:group_identifier).uniq.reject(&:nil?).sort
    grouped = {}

    groups.each do |group|
      grouped[group] = group_template(group)

      group_games = all_games.select { |game| game.group_identifier == group }
      results = evaluate_table_results(group_games, include_teams_without_games: false)

      sorted_results = if direct_comparison
                         sort_by_direct_comparison(results.values, group_games)
                       else
                         results.values.sort_by do |r|
                           [-r[:points], -r[:goals_diff], -r[:goals_scored]]
                         end
                       end

      last_entry = nil
      next_position_diff = 1
      sorted_results.each_with_index do |team_result, index|
        team_result[:sort] = index
        if last_entry.nil?
          team_result[:position] = 1
        elsif (team_result[:points] == last_entry[:points]) &&
              (team_result[:goals_diff] == last_entry[:goals_diff]) &&
              (team_result[:goals_scored] == last_entry[:goals_scored])
          team_result[:position] = last_entry[:position]
          next_position_diff += 1
        else
          team_result[:position] = last_entry[:position] + next_position_diff
          next_position_diff = 1
        end

        last_entry = team_result
      end

      annotate_with_qualifications!(sorted_results)
      grouped[group][:table] = sorted_results
    end

    grouped
  end

  def evaluate_scorer
    game_scores = games.map do |game|
      next unless game.ended? && !game.result.nil?

      game.evaluate_scorer
    end.compact

    result = {}

    game_scores.each do |game_score|
      game_score.each do |player_id, score|
        if result.include?(player_id)
          # sum the items
          result[player_id].each do |key, _|
            next if %i[player_id team_id team_name first_name last_name].include?(key)

            result[player_id][key] += score[key]
          end
        else
          # otherwise just set the score
          result[player_id] = score
        end
      end
    end

    result
  end

  def empty_table_item(team)
    # Punktekorrekturen liegen an der Liga (self-contained pro Saison). Solange
    # eine Liga noch nicht backfilled ist, greift der Fallback auf die globale
    # Setting.point_corrections, damit bestehende Korrekturen weiter wirken.
    league_point_corrections = point_corrections.presence || Setting.point_corrections(id)
    team_point_corrections = league_point_corrections.present? ? league_point_corrections[team.id.to_s] : nil

    {
      games: 0,
      won: 0,
      draw: 0,
      lost: 0,
      won_ot: 0,
      lost_ot: 0,
      goals_scored: 0,
      goals_received: 0,
      goals_diff: 0,
      points: team_point_corrections.present? ? team_point_corrections['points'] : 0,
      team_name: team.name,
      team_id: team.id,
      team_logo: team.logo_url_fallback,
      team_logo_small: team.logo_small_url_fallback,
      point_corrections: team_point_corrections
    }
  end

  def annotate_with_qualifications!(results)
    quals = qualifications.order(:rank_from).to_a
    return if quals.empty?

    results.each do |entry|
      qual = quals.find { |q| entry[:position].between?(q.rank_from, q.rank_to) }
      entry[:qualification_type] = qual&.qualification_type
      entry[:qualification_label] = qual&.label
    end
  end

  def apply_preround_points!(results)
    preround_league = League.find_by(id: league_id_preround)
    return unless preround_league

    multiplier = preround_point_modus == 'half' ? 0.5 : 1.0
    preround_table = preround_league.table

    preround_team_ids = preround_table.map { |e| e[:team_id] }
    preround_club_map = Team.where(id: preround_team_ids).pluck(:id, :club_id).to_h
    preround_points_by_club = preround_table.each_with_object({}) do |entry, map|
      club_id = preround_club_map[entry[:team_id]]
      map[club_id] = (entry[:points] * multiplier).floor if club_id
    end

    current_club_map = Team.where(id: results.keys).pluck(:id, :club_id).to_h

    results.each do |team_id, entry|
      club_id = current_club_map[team_id]
      bonus = preround_points_by_club[club_id] || 0
      next if bonus.zero?

      entry[:points] += bonus
      entry[:preround_points] = bonus
    end
  end

  def evaluate_table_results(g = games, include_teams_without_games: true)
    results = {}

    # Pre-populate all league teams so teams with no games still appear.
    # Nicht für Gruppentabellen: dort ergibt sich die Zugehörigkeit allein aus
    # den Spielen der Gruppe, sonst landen alle Liga-Teams in jeder Gruppe.
    #
    # Mit Logo-Preload, weil empty_table_item je Zeile logo_url_fallback und
    # logo_small_url_fallback liest – dieselbe Stelle wie im Spielplan, nur auf
    # der Tabellenseite (siehe TEAM_WITH_LOGO_PRELOAD).
    if include_teams_without_games
      teams.includes(TEAM_WITH_LOGO_PRELOAD).each { |team| results[team.id] = empty_table_item(team) }
    end

    g.each do |game|
      [game.home_team, game.guest_team].each do |team|
        next unless team

        results[team.id] ||= empty_table_item(team)
      end

      next unless game.ended? && !game.result.nil?

      [game.home_team, game.guest_team].each do |team|
        results[team.id][:games] += 1
      end

      results[game.home_team.id][:goals_scored] += game.result[:home_goals]
      results[game.home_team.id][:goals_received] += game.result[:guest_goals]
      results[game.guest_team.id][:goals_scored] += game.result[:guest_goals]
      results[game.guest_team.id][:goals_received] += game.result[:home_goals]

      # won_points won_overtime_points lost_overtime_points draw_points
      if game.result[:home_goals] == game.result[:guest_goals]
        # draw
        results[game.home_team.id][:draw] += 1
        results[game.guest_team.id][:draw] += 1
        results[game.home_team.id][:points] += draw_points if game.forfait != 3
        results[game.guest_team.id][:points] += draw_points if game.forfait != 3
      elsif game.result[:home_goals] > game.result[:guest_goals]
        # home won
        if game.overtime
          # home won overtime
          results[game.home_team.id][:won_ot] += 1
          results[game.guest_team.id][:lost_ot] += 1
          results[game.home_team.id][:points] += won_overtime_points
          results[game.guest_team.id][:points] += lost_overtime_points
        else
          # home won regular time
          results[game.home_team.id][:won] += 1
          results[game.guest_team.id][:lost] += 1
          results[game.home_team.id][:points] += won_points
        end
      elsif game.result[:home_goals] < game.result[:guest_goals]
        # guest won
        if game.overtime
          # guest won overtime
          results[game.guest_team.id][:won_ot] += 1
          results[game.home_team.id][:lost_ot] += 1
          results[game.guest_team.id][:points] += won_overtime_points
          results[game.home_team.id][:points] += lost_overtime_points
        else
          # guest won regular time
          results[game.guest_team.id][:won] += 1
          results[game.home_team.id][:lost] += 1
          results[game.guest_team.id][:points] += won_points
        end
      end
    end

    results.each_key do |team_id|
      # calculate goal difference
      results[team_id][:goals_diff] = results[team_id][:goals_scored] - results[team_id][:goals_received]
    end

    # point corrections
    results
  end

  def teams
    Team.where(league_id: id).or(Team.where("#{id} = ANY (cup_leagues)")).order(:name)
  end

  # returns:
  # {
  #   id: Int,
  #   leagueName: String,
  #   leagueShortName: String,
  #   matchDays: [
  #     {
  #       games: [ Int ] // Liste von Spiel ids
  #     }
  #   ]
  # }
  def ticker_hash
    {
      id:,
      leagueName: name,
      leagueShortName: short_name,
      sortKey: order_key,
      gameDays: game_days_for_ticker
    }
  end

  def game_days_for_ticker
    gameday_whitelist = Setting.game_day_for_league id, season_id

    temp = {}
    game_days.where(number: gameday_whitelist).includes(:games).each do |gd|
      temp[gd.number] ||= []
      temp[gd.number] << gd.game_ids
      temp[gd.number].flatten!
    end

    temp.map do |k, v|
      {
        gameDayNumber: k,
        title: game_day_title(k.to_s),
        games: v
      }
    end.sort { |a, b| a[:gameDayNumber] <=> b[:gameDayNumber] }
  end

  def game_day_titles
    titles = []
    game_day_numbers.each do |game_day_number|
      titles << game_day_title_hash(game_day_number)
    end

    titles
  end

  def game_day_title_hash(game_day_number)
    { game_day_number:, title: game_day_title(game_day_number) }
  end

  def game_day_title(game_day_number)
    return game_day_title_cup(game_day_number.to_s) if %w[3 4].include?(league_category_id)

    "#{game_day_number}. Spieltag"
  end

  def game_day_title_cup(game_day_number)
    best_of_eight = Setting.start_best_of_eight id

    if best_of_eight.present?
      case game_day_number
      when best_of_eight.to_s
        'Achtelfinale'
      when (best_of_eight + 1).to_s
        'Viertelfinale'
      when (best_of_eight + 2).to_s
        'Halbfinale'
      when (best_of_eight + 3).to_s
        'Finale'
      else
        "Runde #{game_day_number}"
      end
    else
      case game_day_number
      when '4'
        'Achtenfinale'
      when '5'
        'Viertelfinale'
      when '6'
        'Halbfinale'
      when '7'
        'Finale'
      else
        "Runde #{game_day_number}"
      end
    end
  end

  def licenses(full_license_hash = true, only_current_licenses = true)
    League.licenses_for(self, full_license_hash:, only_current_licenses:).fetch(id, [])
  end

  # Lizenzlisten mehrerer Ligen in einem Rutsch: { league_id => [team_item, …] }.
  #
  # Admin::LicensesController#index braucht die Listen über alle Ligen einer
  # Saison. Liga für Liga kostete das je Liga eine eigene Spieler-Abfrage – und
  # das ist ein Sequential Scan über die ganze players-Tabelle, weil die Lizenzen
  # in einer JSONB-Spalte ohne passenden Index liegen – plus je Team die drei
  # ActiveStorage-Zugriffe von Team#full_hash. Gebündelt fällt beides einmal für
  # alle Ligen an, statt einmal pro Liga.
  #
  # team_hash: :light liefert nur die Felder, die Lizenzlisten lesen, und lässt
  # damit die Logo- und Spielbetriebs-Auflösung weg.
  # with_other_licenses: false spart das Nachladen der fremden Teams.
  def self.licenses_for(leagues, full_license_hash: true, only_current_licenses: true,
                        team_hash: :full, with_other_licenses: true)
    leagues = Array(leagues)
    return {} if leagues.empty?

    teams_by_league = license_teams_by_league(leagues, team_hash)
    all_teams = teams_by_league.values.flatten.uniq(&:id)
    team_licenses = Player.find_by_team_ids(all_teams.map(&:id))

    teams_by_id = all_teams.index_by(&:id)
    teams_by_id.merge!(license_foreign_teams(team_licenses, teams_by_id.keys)) if with_other_licenses

    leagues.to_h do |league|
      [league.id, league.build_license_items(teams_by_league[league.id] || [], team_licenses, teams_by_id,
                                             full_license_hash, only_current_licenses,
                                             team_hash, with_other_licenses)]
    end
  end

  # Teams je Liga in einer Abfrage. Deckt wie League#teams auch die Teams ab, die
  # nur über cup_leagues zur Liga gehören.
  def self.license_teams_by_league(leagues, team_hash)
    league_ids = leagues.map(&:id)
    # Sortierung wie League#teams (:name) – die Liga-Lizenzansicht zeigt die
    # Mannschaften alphabetisch und sortiert nicht selbst nach. :id nur als
    # Tiebreaker, damit die Reihenfolge bei gleichem Namen bestimmt bleibt.
    scope = Team.where(league_id: league_ids)
                .or(Team.where('cup_leagues && ARRAY[?]::int[]', league_ids))
                .order(:name, :id)
    # :league für other_licenses (league_name, gf_adult?, female), bei :full
    # zusätzlich alles, was Team#full_hash liest.
    scope = if team_hash == :full
              scope.includes(TEAM_WITH_LOGO_PRELOAD + [{ league: :game_operation }])
            else
              scope.includes(:league)
            end
    teams = scope.to_a
    leagues.to_h do |league|
      [league.id, teams.select { |t| t.league_id == league.id || Array(t.cup_leagues).include?(league.id) }]
    end
  end

  # Teams, auf die Lizenzen zeigen, die keiner der geladenen Ligen gehören.
  def self.license_foreign_teams(team_licenses, known_team_ids)
    known = known_team_ids.to_set
    foreign_team_ids = Set.new
    team_licenses.each_value do |players|
      players.each do |player|
        (player.licenses || []).each do |l|
          t_id = l['team_id'].to_i
          foreign_team_ids << t_id unless known.include?(t_id)
        end
      end
    end
    return {} if foreign_team_ids.empty?

    Team.includes(:league).where(id: foreign_team_ids.to_a).index_by(&:id)
  end

  # Nur die Felder, die die Lizenzlisten lesen – ohne die Logo-Auflösung von
  # Team#full_hash, die pro Team drei ActiveStorage-Zugriffe kostet.
  def self.license_light_team_hash(team)
    { id: team.id, name: team.name, short_name: team.short_name,
      league_id: team.league_id, club_id: team.club_id }
  end

  def build_license_items(league_teams, team_licenses, teams_by_id, full_license_hash,
                          only_current_licenses, team_hash = :full, with_other_licenses = true)
    active_statuses = [License::APPROVED, License::REQUESTED].to_set

    result = []
    league_teams.each do |team|
      team_item = team_hash == :full ? team.full_hash : League.license_light_team_hash(team)

      team_item[:players] = []
      (team_licenses[team.id] || []).each do |player|
        license = player.licenses.find do |l|
          next false unless l['team_id'].to_i == team.id

          lic_season = l['season_id'] || l.dig('league', 'season_id')
          lic_season.nil? || lic_season.to_s == season_id.to_s
        end
        next unless license

        player_item = player.full_hash(full_license_hash, only_current_licenses)

        last_status = license['history']&.max_by { |h| h['created_at'] }
        next unless last_status

        last_status_id = last_status['license_status_id']
        next unless active_statuses.include?(last_status_id.to_i)

        last_status_code = License::NAMES[last_status_id.to_i]

        approved_at = (last_status['created_at'].to_datetime if last_status_id == 1)
        requested_at = license['history'].select do |lh|
                         lh['license_status_id'] == 2
                       end.last&.dig('created_at')&.then { |ts| ts.to_datetime }

        player_item[:team_license] = {
          license:,
          last_status:,
          last_status_id:,
          last_status_code:,
          approved_at:,
          requested_at:
        }

        if with_other_licenses
          player_item[:other_licenses] = other_license_items(player, team.id, teams_by_id, active_statuses)
        end

        team_item[:players] << player_item
      end

      result << team_item
    end

    result
  end

  # Weitere aktive Lizenzen desselben Spielers in dieser Saison, ohne die des
  # übergebenen Teams. Kontext für die Genehmigungskarte.
  def other_license_items(player, team_id, teams_by_id, active_statuses)
    player.licenses.filter_map do |l|
      t_id = l['team_id'].to_i
      next if t_id == team_id

      current_status = l['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
      next unless active_statuses.include?(current_status)

      other_team = teams_by_id[t_id]
      next unless other_team

      other_league = other_team.league
      # Die Saison entscheidet die LIGA der anderen Mannschaft, nicht das Feld
      # season_id im Lizenz-Eintrag. Altbestände tragen dort nichts, und die
      # frühere Bedingung (`lic_season.nil? ||`) liess genau die deshalb als
      # aktuell durch: Lizenzen von 2012 landeten in other_licenses und brachten
      # die Genehmigungskarte dazu, eine Erst-/Zweitlizenz-Zuordnung zu
      # verlangen, die Player#gf_competition_licenses (strikter Saisonvergleich)
      # anschliessend nirgends verbucht hätte.
      next unless other_league && other_league.season_id.to_s == season_id.to_s

      {
        license_id: l['id'],
        team_name: other_team.name,
        league_name: other_league&.short_name,
        last_status_id: current_status,
        # Kontext für die Erst-/Zweitlizenz-Zuordnung bei der Genehmigung:
        # liegt die andere Lizenz im selben GF-Erwachsenen-Wettbewerb?
        gf_adult: other_league&.gf_adult? || false,
        female: other_league&.female,
        gf_role: l['gf_role']
      }
    end
  end

  def licenses_csv
    league_teams = teams.to_a
    team_licenses = Player.find_by_team_ids(league_teams.map(&:id))

    status = { '1' => 'erteilt', '2' => 'beantragt', '3' => 'abgelehnt', '4' => 'gelöscht', '5' => 'Löschung beantragt',
               '6' => 'Transfer', '7' => 'ignoriert' }

    league_teams.each do |team|
      puts team.name
      team_licenses[team.id].each do |player|
        license = player.licenses.find do |l|
          next false unless l['team_id'].to_i == team.id

          lic_season = l['season_id'] || l.dig('league', 'season_id')
          lic_season.nil? || lic_season.to_s == season_id.to_s
        end

        last_status = license['history'].last
        last_status_id = last_status['license_status_id']
        last_status_code = status[last_status_id.to_s]

        approved_at = (last_status['created_at'].to_datetime.strftime('%d.%m.%Y %H:%M:%S') if last_status_id == 1)
        requested_at = license['history'].select do |lh|
                         lh['license_status_id'] == 2
                       end.last&.dig('created_at')&.then { |ts| ts.to_datetime }.strftime('%d.%m.%Y %H:%M:%S')

        puts "#{player.last_name},#{player.first_name},#{last_status_code},#{requested_at},#{approved_at || '-'},#{team.name}"
      end

      nil
    end
  end

  def license_pdf
    file = "#{id}lizenzliste.pdf"
    # return File.open(file) if !force && File.exist?(file)

    pdf = ApplicationController.render pdf: 'report_filename',
                                       save_to_file: file,
                                       save_only: true,
                                       locals: {
                                         league: self
                                       },
                                       disposition: 'inline',
                                       dpi: '300',
                                       lowquality: true,
                                       template: 'leagues/licenses',
                                       header: {
                                         html: {
                                           template: 'leagues/licenses_header',
                                           locals: {
                                             image: ''
                                           }
                                         }
                                       },
                                       footer: {
                                         html: {
                                           template: 'leagues/licenses_footer',
                                           locals: {
                                             league: self
                                           }
                                         }
                                       },
                                       # show_as_html: true,
                                       # model: model,
                                       # dpi: 250,
                                       # viewportSize: "1280x1024",
                                       # footerCenter: "",
                                       # footerLeft: "",
                                       # footerFontSize: 8,
                                       # footerLine: false,
                                       enable_local_file_access: true,

                                       page_size: 'A4',
                                       margin: { top: 24,
                                                 bottom: 20,
                                                 left: 15,
                                                 right: 10 }

    File.open(file, 'wb') do |f|
      f << pdf
    end
  end

  def fix_wrong_settings(female, league_category_id, league_class_id)
    team_ids = teams.map(&:id)

    team_licenses = {}
    teams.each do |team|
      team_licenses[team.id.to_s] = Player.find_by_team_id team.id
    end

    teams.each do |team|
      team_licenses[team.id.to_s].each do |player|
        player.licenses.map! do |license|
          if license['team_id'] == team.id.to_s
            license['league_category_id'] = league_category_id
            license['league_class_id'] = league_class_id
          end
          license
        end
        player.save
      end
    end

    self.female = female
    self.league_category_id = league_category_id
    self.league_class_id = league_class_id

    save
  end

  def delete_games_and_game_days!
    # check for played games
    if games.map(&:deletable?).reduce(&:&)
      ActiveRecord::Base.transaction do
        game_days.each { |gd| gd.games.destroy_all }
        game_days.destroy_all
      end
    end
  end

  def delete_all_licenses!
    teams = Team.where(league_id: id)
    teams.each do |team|
      players = Player.find_by_team_id team.id
      players.each { |p| p.delete_license!(team.id) }
    end
  end

  def remove_games_game_days_licensens_teams!
    ActiveRecord::Base.transaction do
      delete_all_licenses!
      delete_games_and_game_days!
      teams = Team.where(league_id: id)
      teams.destroy_all
    end
  end

  def user_permissions(user)
    perm = []

    go = game_operation_id

    # we calculate the intersection between this and the users permissions
    #  e.g. [0,1] & [0] => [0]
    #  if we have a non empty array, the permission is present.
    global_or_go = [0, go]

    admin = user.permission_hash[:admin].present? && (global_or_go & user.permission_hash[:admin]).present?
    sbk = user.permission_hash[:sbk].present? && (global_or_go & user.permission_hash[:sbk]).present?
    rsk = user.permission_hash[:rsk].present? && (global_or_go & user.permission_hash[:rsk]).present?

    # # edit home team players before game
    # perm << :pregame_edit_home if admin || sbk || (user.permission_hash[:vm].to_a & home_team.all_club_ids).present? || user.permission_hash[:vm].to_a.include?(home_team_id)
    # # edit guest team players before game
    # perm << :pregame_edit_guest if admin || sbk || (user.permission_hash[:vm].to_a & guest_team.all_club_ids).present? || user.permission_hash[:vm].to_a.include?(guest_team_id)

    # # only allowed to edit nominated_referees
    # perm << :edit_referee_nomination if admin || sbk || rsk

    # # edit all game info
    # perm << :edit_game_report if admin || sbk || user.permission_hash[:vm].to_a.include?(game_day_club_id)

    # # edit league
    perm << :update_league if admin || sbk
    perm << :download_template if admin || sbk
    perm << :import_games if admin || sbk
    perm << :delete_league if admin || sbk

    perm
  end

  def self.admin_user_leagues(user)
    result = []
    leagues = League.current_season.with_resolved_media_includes
                    .order(season_id: :desc, game_operation_id: :asc).order('order_key::int')

    # für jeden verband:
    # name, id, kuerzel, ligen
    go_ids = []

    # wenn admin oder sbk global: füge alle hinzu
    ph = user.permission_hash
    if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
      go_ids = GameOperation.all.pluck(:id)
    elsif ph[:admin].present? || ph[:sbk].present?
      go_ids << ph[:admin] if ph[:admin].present?
      go_ids << ph[:sbk] if ph[:sbk].present?
      go_ids.flatten!
    end

    GameOperation.includes(state_association: { logo_attachment: :blob }).find(go_ids).each do |go|
      item = go.meta_hash
      item[:leagues] = leagues.where(game_operation_id: go.id).map(&:full_hash)
      result << item
    end

    result
  end

  def self.admin_league_permissions(user)
    result = []

    # für jeden verband:
    # name, id, kuerzel, ligen
    go_ids = []

    # wenn admin oder sbk global: füge alle hinzu
    ph = user.permission_hash
    if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
      go_ids = GameOperation.all.pluck(:id)
    elsif ph[:admin].present? || ph[:sbk].present?
      go_ids << ph[:admin] if ph[:admin].present?
      go_ids << ph[:sbk] if ph[:sbk].present?
      go_ids.flatten!
    end

    GameOperation.includes(state_association: { logo_attachment: :blob }).find(go_ids).each do |go|
      item = go.meta_hash
      item[:leagues] = leagues.where(game_operation_id: go.id).map(&:full_hash)
      result << item
    end

    result
  end

  def self.user_leagues_license_list(user)
    result = []

    # für jeden verband:
    # name, id, kuerzel, ligen
    go_ids = []

    # wenn admin oder sbk global: füge alle hinzu
    ph = user.permission_hash

    # Alle Rollen additiv auswerten: die frühere if/elsif-Kette ließ die
    # Admin-/SBK-Rolle gewinnen, sodass ein Nutzer mit zusätzlicher VM-/TM-Rolle
    # die Ligen seiner Vereine bzw. Teams außerhalb des eigenen Spielbetriebs
    # nicht mehr sah.
    if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
      go_ids = GameOperation.all.pluck(:id)
    elsif ph[:admin].present? || ph[:sbk].present?
      go_ids << ph[:admin] if ph[:admin].present?
      go_ids << ph[:sbk] if ph[:sbk].present?
      go_ids.flatten!
    end

    # Ligen aus der Verbands-Berechtigung (Admin/SBK) …
    go_leagues = if go_ids.present?
                   League.current_season.with_resolved_media_includes.where(game_operation_id: go_ids)
                         .order(season_id: :desc, game_operation_id: :asc).order('order_key::int').to_a
                 else
                   []
                 end

    # … plus Ligen der eigenen Vereine (VM) und Mannschaften (TM).
    teams = []
    teams += Club.where(id: ph[:vm]).flat_map(&:current_teams) if ph[:vm].present?
    teams += Team.current_season.where(id: ph[:tm]).to_a if ph[:tm].present?
    team_leagues = teams.compact.uniq.flat_map(&:leagues).uniq

    leagues_by_go = (go_leagues + team_leagues).uniq.group_by(&:game_operation_id)

    # Für Admin/SBK bleiben die eigenen Spielbetriebe auch ohne Ligen sichtbar
    # (bisheriges Verhalten); über VM/TM hinzugekommene nur, wenn sie Ligen haben.
    visible_go_ids = (go_ids + leagues_by_go.keys).uniq
    GameOperation.includes(state_association: { logo_attachment: :blob })
                 .where(id: visible_go_ids).order(:id).each do |go|
      item = go.meta_hash
      item[:leagues] = leagues_by_go.fetch(go.id, []).sort_by { |l| l.order_key.to_i }.map(&:full_hash)
      result << item if go_ids.include?(go.id) || item[:leagues].present?
    end

    result
  end

  private

  # Reihenfolge des Spielplans: Spieltag, Datum, Spielnummer, Uhrzeit.
  #
  # Die Spielnummer musste vor die Uhrzeit, weil ein Spieltag, der parallel in
  # mehreren Hallen läuft, sonst nach Uhrzeit quer über die Hallen verzahnt
  # wurde, statt sie als zusammenhängende Blöcke zu zeigen. Vor das Datum darf
  # sie nicht: Ein Spieltag erstreckt sich häufig über mehrere Tage (Playoffs,
  # Pokalrunden, Nachholspiele), und die Nummern folgen dort der Paarung, nicht
  # dem Kalender. Der Spielplan liefe sonst zeitlich rückwärts.
  #
  # game_number ist eine Textspalte und trägt auch nicht-numerische Werte
  # („HF1", „FIN", „Pl. 3" in K.-o.-Runden), die schedule_item alle zu 0 macht.
  # Solche Spiele stehen am Ende ihres Tages und dort nach Uhrzeit, statt vor
  # die durchnummerierten Spiele zu rutschen. Gleiche Regel wie GAME_ORDER in
  # Admin::GameDaysController, das nicht-numerische Nummern ans Ende stellt.
  #
  # game_id zuletzt, damit die Reihenfolge eindeutig ist: sort_by ist nicht
  # stabil, und schedule sortiert ein ganzes Saison-Array, game_day_schedule
  # nur einen Spieltag. Ohne diesen Anker könnten gleiche Schlüssel in den
  # beiden Ansichten unterschiedlich landen.
  def schedule_sort_key(game)
    number = game[:game_number].to_i

    [game[:game_day].to_i, game[:date].to_s, number.positive? ? 0 : 1, number,
     game[:time].to_s, game[:game_id].to_i]
  end

  def group_template(group_identifier)
    return {} if group_identifier.nil?

    group = group_identifier.split('_').last

    {
      group_identifier:,
      name: ['Gruppe ', group.upcase].join
    }
  end

  def sort_by_direct_comparison(results_array, all_games)
    by_points = results_array.group_by { |r| r[:points] }
    sorted = []

    by_points.keys.sort.reverse.each do |pts|
      group = by_points[pts]
      if group.size == 1
        sorted << group.first
        next
      end

      group_ids = group.map { |r| r[:team_id] }.to_set
      h2h_games = all_games.select do |g|
        g.ended? && !g.result.nil? &&
          group_ids.include?(g.home_team_id) &&
          group_ids.include?(g.guest_team_id)
      end

      h2h = group.each_with_object({}) do |r, h|
        h[r[:team_id]] = { points: 0, goals_scored: 0, goals_received: 0 }
      end

      h2h_games.each do |game|
        home_id = game.home_team_id
        guest_id = game.guest_team_id
        h2h[home_id][:goals_scored] += game.result[:home_goals]
        h2h[home_id][:goals_received] += game.result[:guest_goals]
        h2h[guest_id][:goals_scored] += game.result[:guest_goals]
        h2h[guest_id][:goals_received] += game.result[:home_goals]

        if game.result[:home_goals] == game.result[:guest_goals]
          h2h[home_id][:points] += draw_points
          h2h[guest_id][:points] += draw_points
        elsif game.result[:home_goals] > game.result[:guest_goals]
          if game.overtime
            h2h[home_id][:points] += won_overtime_points
            h2h[guest_id][:points] += lost_overtime_points
          else
            h2h[home_id][:points] += won_points
          end
        else
          if game.overtime
            h2h[guest_id][:points] += won_overtime_points
            h2h[home_id][:points] += lost_overtime_points
          else
            h2h[guest_id][:points] += won_points
          end
        end
      end

      sorted.concat(group.sort_by do |r|
        tid = r[:team_id]
        h = h2h[tid]
        h2h_diff = h[:goals_scored] - h[:goals_received]
        [-h[:points], -h2h_diff, -h[:goals_scored], -r[:goals_diff], -r[:goals_scored]]
      end)
    end

    sorted
  end
end
