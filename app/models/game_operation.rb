class GameOperation < ApplicationRecord
  # Erste URL-Segmente, die das Frontend selbst belegt. Der Spielbetriebs-Pfad
  # wird zum ersten Segment der oeffentlichen Adresse (`/<path>/...`), und die
  # Auffangroute ':association' steht dort als LETZTE Route. Ein Pfad aus dieser
  # Liste erzeugt deshalb keinen Konflikt, sondern eine still unerreichbare
  # Verbandsseite: Die konkrete Route gewinnt, der Spielbetrieb kommt nie dran.
  #
  # Bequemlichkeitspruefung, keine Sicherheitsgrenze -- die Liste muss den
  # Top-Level-Routen des Frontends nachgefuehrt werden (app-routing.module.ts und
  # die *routing*.module.ts der oeffentlichen Module). Verschaetzt sie sich nach
  # unten, entsteht wieder nur die unerreichbare Seite von oben; nach oben blockt
  # sie einen freien Pfad, und die Meldung sagt, welcher es war.
  RESERVED_PATHS = %w[
    api-zugang benutzername-vergessen email-bestaetigen live lizenzcheck
    lizenzliste login mein-konto neues-passwort schiedsrichter schiri-feedback
    spieler spielsekretariat spieltagscheckliste transfer-bestaetigung verein
    verwaltung
  ].freeze

  has_many :leagues
  belongs_to :state_association, optional: true
  has_one_attached :banner

  default_scope { order(id: :asc) }

  validates :name, presence: true
  validates :short_name, presence: true
  # Der Pfad ist keine Kuer: Er traegt die oeffentliche Verbandsadresse (#slug)
  # und `by_shortname` findet den Spielbetrieb ausschliesslich darueber. Am
  # 19.08.2026 hatten alle zehn Spielbetriebe auf Produktion einen gesetzten,
  # eindeutigen Kleinbuchstaben-Pfad; die Pflicht schreibt den Bestand fest,
  # statt ihn zu aendern.
  validates :path, presence: true,
                   format: { with: /\A[a-z0-9]+(-[a-z0-9]+)*\z/,
                             message: 'darf nur Kleinbuchstaben, Ziffern und einzelne Bindestriche enthalten' },
                   uniqueness: { case_sensitive: false },
                   exclusion: { in: RESERVED_PATHS,
                                message: 'ist vom Frontend belegt und ergaebe eine unerreichbare Verbandsseite' }
  # Ein Landesverband hat hoechstens einen Spielbetrieb. Ohne diese Pruefung
  # entscheidet bei zwei Saetzen die niedrigere ID darueber, wer die Vereine des
  # ganzen Verbunds verwaltet (siehe .id_by_state_association) -- der zweite
  # Spielbetrieb waere also angelegt, sichtbar und wirkungslos.
  validates :state_association_id, uniqueness: { allow_nil: true,
                                                 message: 'hat bereits einen Spielbetrieb' }
  # Auf game_operations.state_association_id liegt kein Fremdschluessel, und
  # `belongs_to ... optional: true` prueft nichts. Ohne diese Zeile speichert ein
  # Spielbetrieb auch mit einer Verbands-ID, die es nicht gibt: `admin_hash`
  # zeigt dann keinen Verbandsnamen, und Club.responsible_state_association_ids
  # verwirft ihn ueber `.compact`. Er ist fuer nichts zustaendig, und nirgends
  # steht ein Fehler -- genau die Art stillen Widerspruchs, die die Maske
  # beseitigen soll.
  validates :state_association, presence: { message: 'existiert nicht' },
                                if: -> { state_association_id.present? }
  before_validation :normalize_path

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

  # Datensatz fuer die Spielbetriebs-Verwaltung. Bewusst nicht meta_hash:
  # `national` steht dort nicht drin (es gehoert nicht in oeffentliche Antworten)
  # und `path` ist hier der gespeicherte Wert, nicht der ueber #slug abgeleitete
  # -- die Maske muss zeigen, was in der Spalte steht, sonst schreibt das
  # Speichern die Ableitung als eigenen Wert fest.
  def admin_hash
    {
      id: id,
      name: name,
      short_name: short_name,
      path: path,
      slug: slug,
      national: national,
      state_association_id: state_association_id,
      state_association_name: state_association&.name,
      banner_url: banner_url,
      banner_link_url: banner_link_url,
      dependencies: dependency_counts
    }
  end

  # Was an diesem Spielbetrieb haengt. Jede Zahl ist ein Riegel gegen das
  # Loeschen, siehe Admin::GameOperationsController#destroy.
  #
  # Zwei Sorten Eintrag, und beide muessen mit:
  #
  # * Ligen, Dokumentarten, Schiedsrichter-Tags und empfangene Vereinsfreigaben
  #   haengen an einem Fremdschluessel (db/schema.rb). Fehlt einer hier, gibt es
  #   keine Meldung, sondern eine `ActiveRecord::InvalidForeignKey` aus Postgres
  #   -- der Controller antwortet dann 500 „Server-Fehler." und sagt nicht, was
  #   im Weg steht.
  # * Vereine, Benutzerrollen und Schiedsrichter haengen OHNE Fremdschluessel
  #   dran (die Vereinszuordnung ist ueberhaupt abgeleitet). Fehlt einer hier,
  #   verschwindet der Bezug lautlos: Ein Schiedsrichter an diesem Spielbetrieb
  #   ist danach fuer keine RSK mehr sichtbar (Admin::RefereesController), ohne
  #   Fehler und ohne Hinweis.
  def dependency_counts
    {
      leagues: leagues.unscope(:order).count,
      clubs: Club.home_clubs_of([id]).count,
      users: self.class.user_ids_referencing(id).size,
      referees: Referee.where(game_operation_id: id).count,
      document_types: DocumentType.where(game_operation_id: id).count,
      referee_tags: RefereeTag.where(game_operation_id: id).count,
      releases: StateAssociationRelease.where(recipient_game_operation_id: id).count
    }
  end

  # Benutzer, deren `permissions` auf diesen Spielbetrieb verweisen.
  #
  # In Ruby und nicht per jsonb-Containment: `permissions` traegt die
  # game_operation_id teils als Zahl, teils als String (Altbestand), und
  # `@> '[{"game_operation_id": 5}]'` findet die String-Variante nicht. Bei einer
  # Loeschpruefung waere das der schlimmste Fehler von beiden -- der Riegel
  # griffe nicht, und die Rolle zeigte danach auf eine ID, die es nicht mehr
  # gibt. `permission_hash` selbst rechnet aus demselben Grund mit `.to_i`.
  #
  # Ohne `not_archived`: Ein vor Jahren archiviertes SBK-Konto haelt den
  # Spielbetrieb dauerhaft undloeschbar, und die Meldung nennt keinen
  # Benutzernamen -- die Benutzerverwaltung listet archivierte Konten nicht,
  # der Riegel waere also nicht aufloesbar. Anmelden kann sich ein solches
  # Konto nicht (ApplicationController#current_user), seine Rolle richtet
  # deshalb keinen Schaden an.
  def self.user_ids_referencing(go_id)
    User.not_archived.where.not(permissions: nil)
        .pluck(:id, :permissions)
        .select do |_id, perms|
          perms.is_a?(Array) && perms.any? { |perm| perm.is_a?(Hash) && perm['game_operation_id'].to_i == go_id }
        end
        .map(&:first)
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

  private

  # Leerzeichen und Grossschreibung raeumt das Modell auf, damit Konsole und
  # Maske dieselbe Invariante halten. Aus einem gesetzten Pfad wird darueber
  # hinaus nichts gebastelt: Enthaelt er Umlaute oder Leerzeichen, gibt es eine
  # Fehlermeldung statt einer stillen Ableitung -- der Pfad steht in Adressen,
  # die Vereine verschicken, und soll bewusst gesetzt sein.
  #
  # Ist er leer, wird er aus dem Kuerzel abgeleitet. Genau das tat #slug bisher
  # beim Lesen, und die Trennung war ein Fehler: `by_shortname` sucht
  # ausschliesslich in der Spalte `path`. Ein Spielbetrieb ohne Pfad bekam also
  # oeffentliche Links auf `short_name.parameterize` -- und unter dieser Adresse
  # fand ihn der Endpunkt nicht. Beim Schreiben abzuleiten laesst beide Seiten
  # denselben Wert sehen und macht ihn zugleich der Eindeutigkeitspruefung
  # zugaenglich.
  def normalize_path
    self.path = path.strip.downcase if path.is_a?(String)
    self.path = short_name.parameterize if path.blank? && short_name.present?
  end
end
