class Team < ApplicationRecord
  belongs_to :league
  belongs_to :club

  validates :name, presence: true

  # Vier Zeichen wie beim Verein, plus Leerzeichen und römische Nummer für die
  # weiteren Mannschaften ("BW96 III"). Auf Produktion tragen 104 der 502
  # Mannschaften der laufenden Saison bereits ein Leerzeichen im Kürzel.
  #
  # Acht und nicht sieben, weil die dritte Mannschaft drei Zeichen für die
  # Nummer braucht. Bei sieben wäre "BW96 III" auf "BW96 II" gekappt worden und
  # hätte auf der Anzeigetafel wie die zweite Mannschaft geheißen – genau die
  # Verwechslung, die diese Änderung beseitigt.
  SHORT_NAME_MAX = 8

  # `if:` statt unbedingt: Bestandswerte sind länger als die neue Grenze, und
  # eine unbedingte Prüfung hätte jedes Speichern dieser Mannschaft blockiert –
  # auch dort, wo das Kürzel gar nicht vorkommt. Ein Teammanager, der nur die
  # Feedback-Kontaktadresse setzt (UserRefereeFeedbackSettingsController), wäre
  # an einer Meldung über das Kürzel hängengeblieben, das er selbst nicht
  # bearbeiten kann. Ebenso hätte eine einzige überlange Quell-Mannschaft die
  # ganze Liga-Kopie zurückgerollt.
  validates :short_name, length: { maximum: SHORT_NAME_MAX },
                         allow_blank: true, if: :short_name_changed?

  # Siehe Game: Einladungen zum Schiri-Feedback dürfen ihr Spiel bzw. ihre
  # Mannschaft nicht überleben (gültiger Token plus Mailadresse).
  has_many :referee_feedback_invitations, dependent: :destroy

  has_one_attached :logo

  scope :by_club_id, ->(cid) { where(club_id: cid).or(Team.where('? = ANY (syndicate_clubs)', cid)) }
  # "Aktuelle Saison" = Teams, deren Liga in der aktuellen Saison (season_id) liegt.
  # Subquery statt joins, damit nachgelagerte .where(id:/club_id:) eindeutig bleiben.
  # (Früher: league_id >= Setting.current_min_league — eine reine ID-Schwelle, die
  # frisch importierte Alt-Saisons mit hohen league_ids fälschlich als aktuell
  # einstufte; season_id ist die korrekte Abgrenzung.)
  scope :current_season, -> { where(league_id: League.current_season.select(:id)) }

  def tasks
    Task.where('home_team = ? OR guest_team = ?', id, id)
  end

  def all_league_ids
    [cup_leagues, league_id].compact.flatten
  end

  def leagues
    League.where(id: all_league_ids)
  end

  # Die Liga, die die Elternzustimmung verlangt – oder nil, wenn keine sie
  # verlangt. Eine Mannschaft spielt über `leagues` neben ihrer Hauptliga auch in
  # Pokal-Ligen, die einem anderen Verband gehören können, und jede davon kann
  # das Flag tragen. Deshalb reicht ein Ja/Nein nicht: Antragsformular und
  # Art.-13-Mail müssen dieselbe Liga benennen, sonst liest die gesetzliche
  # Vertretung im Formular von der einen und in der Mail von der anderen.
  #
  # Die Hauptliga hat Vorrang, weil sie der Regelfall ist. Ohne diesen Vorrang
  # entscheidet der default_scope von League (season_id, game_operation_id,
  # order_key) darüber, welche Liga gewinnt, und der stellt Pokal-Ligen fremder
  # Verbände je nach game_operation_id vor die eigene Hauptliga.
  #
  # Zwei `detect` statt eines sortierten Durchlaufs: `Array#sort_by` ist in MRI
  # nicht stabil und wirft ab acht gleichrangigen Elementen die Reihenfolge
  # durcheinander. Ausgerechnet in einer Methode, die Bestimmtheit herstellen
  # soll, waere das die falsche Grundlage.
  def parental_consent_league
    candidates = leagues.to_a
    candidates.detect { |l| l.id == league_id && l.parental_consent_required } ||
      candidates.detect(&:parental_consent_required)
  end

  def licenses
    Player.find_by_team_id(id)
  end

  def all_club_ids
    ids = [club_id]
    ids += syndicate_clubs if syndicate && syndicate_clubs

    ids.uniq
  end

  def all_clubs
    Club.where(id: all_club_ids)
  end

  def self.teams_by_season(season_id)
    League.where(season_id:).map(&:teams).flatten.uniq
  end

  def logo_url
    Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true) if logo.attached?
  end

  def logo_small_url
    return nil unless logo.attached?

    Rails.application.routes.url_helpers.rails_representation_path(
      logo.variant(resize_to_fit: [100, 100]),
      only_path: true
    )
  end

  def logo_url_fallback
    return logo_url if logo_url.present?

    club&.logo_url
  end

  def logo_small_url_fallback
    return logo_small_url if logo_small_url.present?

    club&.logo_small_url
  end

  def full_hash(with_contact_person = false)
    h = {
      id:,
      name:,
      short_name:,
      logo: logo_url,
      league_id:,
      cup_leagues:,
      club_id:,
      league_name: league&.name,
      league_short_name: league&.short_name,
      game_operation_id: league&.game_operation&.id,
      game_operation_name: league&.game_operation&.name,
      game_operation_short_name: league&.game_operation&.short_name,
      game_operation_slug: league&.game_operation&.slug,
      syndicate:,
      syndicate_clubs:,
      logo_url: logo_url_fallback,
      logo_small: logo_small_url_fallback
    }

    if with_contact_person
      h[:contact_email] = contact_email
      h[:contact_person] = contact_person
    end

    h
  end

  def licenses(full_license_hash = true, only_current_licenses = true, player_hash_type = :full)
    team_item = full_hash
    team_players = Player.find_by_team_id id

    team_item[:players] = []
    team_players.each do |player|
      player_item = player.some_hash(player_hash_type, full_license_hash, only_current_licenses)

      license = player.licenses.select { |l| l['team_id'].to_i == id }.first
      # license bzw. dessen history kann fehlen/leer sein (z. B. Preround-Kopie
      # ohne "beantragt"-Eintrag oder kein Team-Match) – dann bleiben die
      # Status-Felder nil statt die Team-Lizenzliste abzubrechen.
      history = license&.dig('history') || []

      last_status = history.sort_by { |h| h['created_at'] }.last
      last_status_id = last_status&.dig('license_status_id')
      last_status_code = last_status_id && License::NAMES[last_status_id.to_i]

      approved_at = (last_status['created_at'].to_datetime if last_status_id == 1)
      requested_at = history.select do |lh|
                       lh['license_status_id'] == 2
                     end.last&.dig('created_at')&.to_datetime

      player_item[:team_license] = {
        license:,
        last_status:,
        last_status_id:,
        last_status_code:,
        approved_at:,
        requested_at:
      }

      team_item[:players] << player_item
    end

    team_item
  end

  # {
  #     shortName: String, // Kürzel, das wir verwenden, wenn kein Logo hinterlegt ist
  #     name: String,
  #     logoUrl: String
  #   }
  def ticker_hash
    {
      shortName: ticker_short_name,
      name:,
      logoUrl: logo_url
    }
  end

  # Kürzel für Ticker und Livestream-Overlay, in dieser Reihenfolge:
  # Mannschaft, sonst Verein, sonst Name.
  #
  # Der Verein als Zwischenstufe, weil 449 Mannschaften gar kein eigenes Kürzel
  # tragen; für die stand bisher der abgeschnittene Name auf der Anzeigetafel.
  # Der Name bleibt letzte Rettung: teams.short_name ist nullable, und ohne
  # Wert starb `slice` mit NoMethodError und riss die ganze Ticker-Antwort mit
  # (die v1-Route liefert alle Spiele einer Liga auf einmal, eine Mannschaft
  # ohne Kürzel machte also die komplette Anzeigetafel unbrauchbar).
  #
  # `.split(' ').first` ist bewusst entfallen: Es warf die römische Nummer weg,
  # "ETV II" wurde zu "ETV". Die zweite Mannschaft war damit auf der
  # Anzeigetafel nicht von der ersten zu unterscheiden.
  def ticker_short_name
    roh = short_name.presence || club&.short_name.presence || name
    roh.to_s.strip.slice(0, SHORT_NAME_MAX).strip
  end

  def user_permissions(user)
    perm = []

    go = league&.game_operation_id

    # we calculate the intersection between this and the users permissions
    #  e.g. [0,1] & [0] => [0]
    #  if we have a non empty array, the permission is present.
    global_or_go = go.present? ? [0, go] : [0]

    admin = user.permission_hash[:admin].present? && (global_or_go & user.permission_hash[:admin]).present?
    sbk = user.permission_hash[:sbk].present? && (global_or_go & user.permission_hash[:sbk]).present?

    # # edit league
    perm << :update_team if admin || sbk
    perm << :delete_team if admin || sbk

    perm
  end

  def self.add_teams_to_cup!(team_ids, cup_id)
    teams = Team.find(team_ids)

    teams.each do |team|
      team.cup_leagues ||= []
      team.cup_leagues << cup_id
      team.save
    end
  end

  def add_logo(force = false)
    return if !force && logo.attached?

    dir = Dir["tmp/logoteams/#{id}*.png"]
    return unless dir.present?

    path = dir.first
    filename = path.split('/').last

    logo.attach(io: File.open(path), filename:, content_type: 'image/png')
  end

  def self.add_logos
    teams = Team.all
    teams.each do |team|
      team.add_logo
    end
  end
end
