class GameOperation < ApplicationRecord
  has_many :leagues
  belongs_to :state_association, optional: true
  has_one_attached :banner

  default_scope { order(id: :asc) }

  # Vereine, deren HEIMAT-Spielbetrieb dieser ist – die Vereine also, die diesem
  # Verband gehören. Maßgeblich für Zugriff auf die Vereinsstammdaten; darüber
  # hinaus gibt es Lesezugriff nur per Vereins-Freigabe
  # (StateAssociationRelease).
  #
  # Der frühere `#clubs` matchte den gesamten game_operations_hash und zog damit
  # auch bloße Gast-Einträge heran. Er hatte zuletzt keinen Aufrufer mehr und ist
  # mit dem Gast-Eintrag selbst entfallen.
  def home_clubs
    Club.where(
      'clubs.game_operations_hash @> ?',
      [{ game_operation_id: id, home_game_operation: true }].to_json
    ).order(:name)
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
