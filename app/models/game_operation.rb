class GameOperation < ApplicationRecord
  has_many :leagues
  belongs_to :state_association, optional: true
  has_one_attached :banner

  default_scope { order(id: :asc) }

  after_commit { Current.reset_association_structure }

  # Spielbetrieb je Landesverband, die zweite Haelfte der
  # Zustaendigkeitsableitung am Verein (Club#main_game_operation_id):
  # Landesverband, Wurzel der Verbandskette, Spielbetrieb dieser Wurzel.
  #
  # Zwischengespeichert in Current und nicht in Rails.cache, Begruendung dort.
  #
  # Ein Landesverband hat hoechstens einen Spielbetrieb; am 19.08.2026 galt das
  # auf Produktion fuer alle zehn Spielbetriebe (bei 14 Landesverbaenden, vier
  # davon ohne eigenen). Gaebe es doch zwei, gewinnt der mit der niedrigeren ID
  # (`||=` auf der von default_scope nach ID sortierten Liste), damit die
  # Zustaendigkeit eindeutig bleibt statt je Prozess anders auszufallen.
  def self.id_by_state_association
    Current.game_operation_id_by_state_association ||=
      where.not(state_association_id: nil).pluck(:state_association_id, :id)
           .each_with_object({}) { |(sa_id, go_id), map| map[sa_id] ||= go_id }
  end

  # Alle Spielbetriebe nach ID, je Request einmal geladen. Bei rund zehn Saetzen
  # billiger als eine Abfrage je Nachschlag -- und die gab es: Club#home_game_operation
  # laeuft in Player#create_license_hash je Lizenzzeile, in den Lizenzlisten also
  # je Spieler. Vorher hing dort ein wochenlanger Rails.cache-Eintrag, der mit der
  # Ableitung entfallen ist.
  def self.by_id
    Current.game_operations_by_id ||= all.index_by(&:id)
  end

  # Vereine, fuer die dieser Spielbetrieb zustaendig ist: die Vereine seines
  # Verbunds und aller Verbaende darunter -- sofern er der zustaendige
  # Spielbetrieb dieses Verbunds ist. Ein Spielbetrieb an einem UNTERGEORDNETEN
  # Verband hat keine Vereine, auch wenn unter diesem Verband welche haengen;
  # zustaendig ist dann der Spielbetrieb des Verbunds (siehe
  # Club.responsible_state_association_ids und den Test dazu in club_test.rb).
  #
  # Massgeblich fuer Zugriff auf die Vereinsstammdaten; darueber hinaus gibt es
  # Lesezugriff nur per Vereins-Freigabe (StateAssociationRelease).
  #
  # Frueher stand die Zuordnung als Heimat-Eintrag im `game_operations_hash` des
  # Vereins. Siehe Club#main_game_operation_id, warum sie jetzt abgeleitet wird.
  def home_clubs
    Club.home_clubs_of([id]).order(:name)
  end

  def games
    leagues.map(&:games).flatten.sort_by { |i| i.game_number.to_i }
  end

  def top_leagues
    # Mit Vorladen: short_hash ruft je Liga full_hash, das über resolved_logo
    # und resolved_banner bis zum Landesverband greift. Diese Antwort steckt in
    # /api/v2/init, dem ersten Abruf jedes Seitenaufbaus.
    leagues.current_season.with_resolved_media_includes.first(5)
  end

  def slug
    path.presence || short_name&.parameterize
  end

  def banner_url
    Rails.application.routes.url_helpers.rails_blob_path(banner, only_path: true) if banner.attached?
  end

  def meta_hash
    hash = attributes.with_indifferent_access.slice(:id, :name, :short_name, :path,
                                                    :state_association_id, :banner_link_url)
    hash[:path] = slug
    hash[:banner_url] = banner_url
    # Einzige Logo-Quelle ist der Upload am Landesverband (Verbandseinstellungen).
    # Der frühere Rückfall auf die Textspalte game_operations.logo_url ist entfallen:
    # Für die Spalte gab es keine Pflege-Oberfläche, die Werte zeigten teils auf
    # fremde Server, und solange sie irgendetwas lieferte, blieb ein fehlender
    # Upload unbemerkt. Ohne Upload ist logo_url jetzt nil, das Frontend zeigt
    # dann den Verbandsnamen statt eines Bildes.
    hash[:logo_url] = state_association&.logo_url
    hash
  end

  def short_hash
    result = meta_hash
    result[:top_leagues] = top_leagues.map(&:full_hash)
    result
  end

  def user_permissions(user)
    perm = []

    go = id

    # we calculate the intersection between this and the users permissions
    #  e.g. [0,1] & [0] => [0]
    #  if we have a non empty array, the permission is present.
    global_or_go = [0, go]

    admin = user.permission_hash[:admin].present? && (global_or_go & user.permission_hash[:admin]).present?
    sbk = user.permission_hash[:sbk].present? && (global_or_go & user.permission_hash[:sbk]).present?
    rsk = user.permission_hash[:rsk].present? && (global_or_go & user.permission_hash[:rsk]).present?

    perm << :create_league if admin || sbk
    perm << :create_team if admin || sbk
    perm << :index_clubs if admin || sbk
    perm << :create_club if admin || sbk

    perm
  end
end
