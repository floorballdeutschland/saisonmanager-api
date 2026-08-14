class Club < ApplicationRecord
  has_many :game_days
  belongs_to :state_association, optional: true

  has_one_attached :logo

  # Das Kürzel ist ein Anzeigezeichen, kein Name: Es steht auf der
  # Anzeigetafel des Livestreams, wo mehr als vier Zeichen die Bauchbinde
  # sprengen. Bestandswerte sind länger, deshalb nur beim Speichern geprüft
  # und Leerwerte erlaubt (das Feld ist nullable).
  SHORT_NAME_MAX = 4

  validates :short_name, length: { maximum: SHORT_NAME_MAX }, allow_blank: true

  scope :active, -> { where(deactivated_at: nil) }

  def deactivate!(user_id)
    update!(deactivated_at: Time.current, deactivated_by: user_id)
  end

  def reactivate!
    update!(deactivated_at: nil, deactivated_by: nil)
  end

  def teams
    Team.by_club_id(id)
  end

  def current_teams
    teams.current_season
  end

  # include_deactivated: true nimmt die Deaktivierten dieses Vereins mit. Bei einer
  # noch offenen oder noch gültigen Zugehörigkeit genügt dafür der Status; eine bereits
  # geschlossene zählt nur, wenn Player#membership_closed_by_deactivation? sie der
  # Deaktivierung zurechnet – dieselbe Bedingung, unter der reactivate! sie wieder
  # öffnet. Ohne diesen Zweig fallen frisch Deaktivierte sowohl durch Player.active als
  # auch durch die valid_until-Prüfung (deactivate! setzt valid_until = jetzt) und wären
  # in der Vereinsliste nicht mehr reaktivierbar.
  #
  # merged_into_id: zusammengeführte Dubletten bleiben draußen, siehe
  # PlayersController#reactivate.
  def players(include_deactivated: false)
    scope = include_deactivated ? Player.where(merged_into_id: nil) : Player.active
    p = scope.where("players.clubs @> '[{\"club_id\": ?}]'", id).order(:last_name, :first_name)
    p.select do |pl|
      pl.clubs.map do |c|
        if c['club_id'] != id
          false
        elsif c['valid_until'].blank?
          true
        elsif c['valid_until'].to_date >= Time.now
          true
        else
          include_deactivated && pl.membership_closed_by_deactivation?(c)
        end
      end.reduce(&:|)
    end
  end

  # Enthält genau einen Eintrag: den Heimat-Spielbetrieb des Vereins
  # (`home_game_operation: true`). Bis Release 1.78 standen hier zusätzlich
  # Gast-Einträge (`home_game_operation: false`) aus dem Altdaten-Import
  # 2010–2014. Die Anwendung hat sie nie geschrieben und nie nachgeführt, und
  # seit 1.67.1 entschied auch keine Rechteprüfung mehr über sie. Sie sind
  # ersatzlos entfallen: Wer fremde Vereine sehen muss, bekommt eine
  # Vereins-Freigabe des zuständigen Landesverbands
  # (StateAssociationRelease) oder ist über die Liga zuständig.
  #
  # Die Array-Form bleibt, weil die jsonb-Abfragen (`@>`) darauf aufbauen.
  def game_operations_hash
    val = super
    val.is_a?(Array) ? val : []
  end

  def home_game_operation
    Rails.cache.fetch("#{cache_key}/home_game_operation", expires_in: 1.week) do
      go = game_operations_hash.select { |g| g['home_game_operation'] == true }
      GameOperation.find_by_id go.first['game_operation_id'] if go.present?
    end
  end

  def update_state
    return if postcode.blank?

    states = Club.postcodes.select { |pc| pc[:from] < postcode.to_i && pc[:till] > postcode.to_i }

    if states.present?
      state = states.first[:isocode]
      update_attributes(state:)
    end
  end

  def full_hash
    {
      id:,
      long_name:,
      name:,
      short_name:,
      state:,
      state_association_id:,
      contact_email:,
      logo_url:,
      logo_small_url:,
      game_operation_id: main_game_operation_id,
      deactivated_at:,
      deactivated_by:
    }
  end

  # Öffentliche Variante von full_hash – ohne contact_email und interne Felder
  # (deactivated_*), für key-geschützte öffentliche Endpunkte.
  def public_hash
    {
      id:,
      long_name:,
      name:,
      short_name:,
      state:,
      state_association_id:,
      logo_url:,
      logo_small_url:,
      game_operation_id: main_game_operation_id
    }
  end

  # Boolean-Cast statt Truthy-Prüfung, aus demselben Grund wie in
  # Player#home_club_hash: In Altdaten liegt das Flag als String, und `'false'`
  # ist truthy. Ein Gast-Eintrag mit diesem Wert galt damit als Heimat-Eintrag —
  # und weil diese Methode den zuständigen Verband bestimmt, bekam die SBK des
  # Gastverbands Zugriff auf jeden Spieler mit Heimat in diesem Verein.
  #
  # `Club#home_game_operation` und die SQL-Bedingung in
  # `without_home_game_operation` prüfen bereits strikt auf `true`; hier lief es
  # auseinander: Derselbe Verein galt dort als „ohne Heimat-Spielbetrieb" und
  # hier als zugeordnet.
  def main_game_operation_id
    game_operations_hash.filter { |h| ActiveModel::Type::Boolean.new.cast(h['home_game_operation']) }
                        .map { |h| h['game_operation_id'].to_i }.first
  end

  # Darf ein Admin-/SBK-Scope diesen Verein LESEN? Genau zwei Gründe:
  # der Heimat-Spielbetrieb des Vereins, oder eine aktuelle Vereins-Freigabe
  # (StateAssociationRelease) des Landesverbands, dem der Verein gehört.
  #
  # Einzige Quelle für diese Regel. Vorher stand sie dreimal getrennt im Code
  # (Vereinsliste, Vereins-Detail, Spielerliste eines Vereins) – und lief
  # auseinander: Das Detail kannte die Freigabe, die Spielerliste nicht, und
  # beide zogen zusätzlich bloße Gast-Einträge aus dem game_operations_hash
  # heran, die niemand erteilt hatte.
  #
  # `go_ids` ohne die globale 0 übergeben; globalen Zugriff prüfen die Aufrufer
  # vorher selbst.
  def readable_by_game_operations?(go_ids)
    scope = Array(go_ids).compact.map(&:to_i).reject(&:zero?)
    return false if scope.empty?
    return true if scope.include?(main_game_operation_id)
    return false if state_association_id.blank?

    StateAssociationRelease.current_season
                           .where(recipient_game_operation_id: scope,
                                  grantor_state_association_id: state_association_id)
                           .exists?
  end

  def fix_game_operations_hash!
    game_operations_hash.map! do |goh|
      if goh['game_operation_id'].present? && goh['game_operation_id'].instance_of?(String)
        goh['game_operation_id'] = goh['game_operation_id'].to_i
      end

      goh
    end

    save
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

  def user_permissions(user)
    perm = []

    go = main_game_operation_id
    global_or_go = [0, go]
    ph = user.permission_hash

    admin = ph[:admin].present? && (global_or_go & ph[:admin]).any?
    sbk = ph[:sbk].present? && (global_or_go & ph[:sbk]).any?

    perm << :update_club if admin || sbk
    perm << :update_player if admin || sbk

    if admin || sbk || ph[:vm].present? && ph[:vm].include?(id)
      perm << :create_player
    end

    perm
  end

  # Vereine, für die der User vereinsgebundene Rollen (VM/TM) vergeben darf:
  # die eigenen VM-Vereine plus die Vereine der eigenen SBK-Spielbetriebe.
  #
  # Für die SBK-Rolle ist der Heim-Spielbetrieb des Vereins maßgeblich
  # (main_game_operation_id), analog zu :update_club in #user_permissions – ein
  # Verein, der in einem fremden Spielbetrieb nur als Gast antritt, gehört nicht
  # dazu. Freigaben nach StateAssociationRelease zählen ebenfalls nicht, die
  # gewähren nur Lesezugriff (siehe .admin_user_clubs).
  #
  # Einzige Quelle für das Vereins-Dropdown der Benutzeranlage und die Prüfung in
  # Admin::UsersController#create, damit die Auswahl nicht Vereine anbietet, die
  # beim Speichern abgelehnt werden.
  def self.role_assignable_for(user, include_deactivated: false)
    scope = include_deactivated ? all : active
    ph = user.permission_hash

    return scope.order(:name) if ph[:admin].present? || ph[:sbk]&.include?(0)

    # Alle Rollen additiv auswerten, nicht per elsif-Kette nur die erste: wer
    # neben einer regionalen SBK-Rolle auch VM ist, verlor sonst genau die
    # eigenen Vereine, die außerhalb der SBK-Spielbetriebe liegen – obwohl eine
    # reine VM dort Konten anlegen darf.
    ids = Array(ph[:vm])
    if ph[:sbk].present?
      ids += scope.select { |c| ph[:sbk].include?(c.main_game_operation_id) }.map(&:id)
    end

    scope.where(id: ids.uniq).order(:name)
  end

  # Vereine ohne eigenen Landesverband landen in der Gruppe des Bundesverbands –
  # er ist für sie zuständig. Fehlt der Datensatz, stehen sie in der Restgruppe
  # „Ohne Landesverband" (siehe orphan_group); verloren gehen sie also nie.
  #
  # Auflösung bewusst über das Kürzel und nicht über eine feste ID: in
  # Produktion hat der FVD zwar id 1, db/seeds.rb legt dort aber „SBK Ost" an.
  # Eine hartkodierte 1 hätte die Vereine ohne Landesverband in jeder
  # aufgesetzten Datenbank unter genau den Dachverband gruppiert, den diese
  # Gruppierung loswerden soll – und zwar völlig lautlos.
  FALLBACK_STATE_ASSOCIATION_SHORT_NAME = 'FVD'.freeze

  # Vereine ohne Heim-Spielbetrieb: kein Verband ist für sie zuständig.
  # `@>` mit Teilobjekt matcht jeden Eintrag mit home_game_operation: true,
  # unabhängig vom Spielbetrieb; die Negation trifft damit leere Hashes und
  # solche mit ausschließlich Gast-Einträgen.
  WITHOUT_HOME_GAME_OPERATION_SQL =
    %(NOT (clubs.game_operations_hash @> '[{"home_game_operation": true}]')).freeze

  # Gruppiert die Vereine nach ihrem *eingestellten* Landesverband
  # (clubs.state_association_id) statt nach Spielbetrieb. Vorher richtete sich
  # die Überschrift nach dem Spielbetrieb und widersprach damit dem, was im
  # Verein selbst eingestellt ist – z. B. erschienen Vereine mit Landesverband
  # Schleswig-Holstein unter „Floorball Niedersachsen". Untergeordnete
  # Landesverbände (Sachsen, Sachsen-Anhalt, Thüringen) werden dadurch einzeln
  # sichtbar statt gesammelt unter „SBK Ost".
  #
  # Der Zugriffsumfang bleibt unverändert am Spielbetrieb: welche Vereine jemand
  # sieht, richtet sich weiter nach seinen GameOperation-Rechten – nur die
  # Gruppierung folgt dem Landesverband. Ein Verein im eigenen Spielbetrieb, der
  # einem anderen Landesverband angehört (z. B. ETV Hamburg im Spielbetrieb
  # Niedersachsen), bleibt deshalb sichtbar, nur unter der Überschrift seines
  # eigenen Landesverbands.
  def self.admin_user_clubs(user, include_deactivated: false)
    ph = user.permission_hash
    global_access = ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)

    club_scope = include_deactivated ? Club.all : Club.active

    go_ids = []
    if global_access
      go_ids = GameOperation.all.pluck(:id)
    elsif ph[:admin].present? || ph[:sbk].present?
      go_ids << ph[:admin] if ph[:admin].present?
      go_ids << ph[:sbk] if ph[:sbk].present?
      go_ids.flatten!
    end

    # Vereine ohne Heim-Spielbetrieb nur für globalen Zugriff: sie sind sonst
    # unsichtbar und nicht bearbeitbar (in Produktion 13 neu angelegte Vereine).
    # Ein einzelner Landesverband soll dafür aber nicht die unzugeordneten
    # Vereine aller anderen in seiner Liste haben.
    scoped = home_clubs_of(go_ids, include_unassigned: global_access)
      .includes(logo_attachment: :blob)
    scoped = scoped.active unless include_deactivated
    clubs = scoped.order(:name).to_a

    go_sa_ids = GameOperation.where(id: go_ids).pluck(:state_association_id).compact.uniq
    result = group_by_state_association(clubs, go_sa_ids)
    covered_club_ids = clubs.map(&:id)

    unless global_access
      released = released_state_association_groups(go_ids, club_scope, covered_club_ids)
      result.concat(released)
      covered_club_ids += released.flat_map { |g| g[:clubs].pluck(:id) }

      own = own_clubs_group(ph, club_scope, covered_club_ids)
      result << own if own
    end

    result
  end

  # Heim-Vereine aller übergebenen Spielbetriebe – in einer Query statt einer pro
  # Spielbetrieb. Auf clubs liegt derzeit kein Index, die @>-Bedingungen wären
  # aber mit einem GIN-Index auf game_operations_hash index-fähig. Bei knapp 300
  # Vereinen ist der Sequential Scan unkritisch.
  #
  # Nur Heim-Einträge: Ein Verein gehört genau einem Verband, und nur der
  # verwaltet seine Stammdaten. Ein bloßer Gast-Eintrag im game_operations_hash
  # reicht dafür nicht – die Einträge stammen aus dem Altdaten-Import 2010–2014,
  # werden von der Anwendung nie geschrieben und nicht nachgeführt. Sie ließen
  # die Verbände gegenseitig in ihre Vereinslisten sehen, ohne dass es jemand
  # erteilt hätte. Fremde Vereine erscheinen nur über eine Vereins-Freigabe, also
  # im „(freigegeben)"-Block.
  def self.home_clubs_of(go_ids, include_unassigned: false)
    predicates = Array.new(go_ids.size, 'clubs.game_operations_hash @> ?')
    binds = go_ids.map do |id|
      [{ game_operation_id: id.to_i, home_game_operation: true }].to_json
    end

    # Ohne Bind-Platzhalter und deshalb hinter den Spielbetriebs-Bedingungen:
    # die Binds werden positionsabhängig eingesetzt.
    predicates << WITHOUT_HOME_GAME_OPERATION_SQL if include_unassigned
    return none if predicates.empty?

    # Klammern explizit, obwohl Rails String-Prädikate ohnehin in
    # Arel::Nodes::Grouping wickelt: so ist die Bindung beim Lesen von to_sql
    # eindeutig, und eine Weiterverwendung des Fragments außerhalb von `where`
    # (to_sql, find_by_sql) verknüpft das OR nicht versehentlich mit einem AND.
    where("(#{predicates.join(' OR ')})", *binds)
  end

  # Baut je Landesverband eine Gruppe.
  #
  # Landesverbände der eigenen Spielbetriebe erscheinen auch ohne Vereine. Sonst
  # verschwände ein Verband, dem noch kein Verein zugeordnet ist, komplett aus
  # der Vereinsverwaltung – und mit ihm der Knopf zum Anlegen des ersten
  # Vereins, der in der Oberfläche je Gruppe steht.
  #
  # Alle Gruppenköpfe kommen aus einer einzigen Query samt Logo-Attachment
  # (vgl. Issue #193): die Landesverbände der Vereine, die der Spielbetriebe,
  # deren Unterverbände und der Bundesverband. Letzterer steckt bewusst in
  # derselben Query – ein eigenes find_by hätte den N+1-Test aus #193 gerissen.
  def self.group_by_state_association(clubs, go_state_association_ids)
    grouped = clubs.group_by(&:state_association_id)

    associations = StateAssociation.includes(logo_attachment: :blob)
      .where('state_associations.id IN (:ids) OR state_associations.parent_id IN (:parents) ' \
             'OR state_associations.short_name = :national',
             ids: grouped.keys.compact + go_state_association_ids,
             parents: go_state_association_ids,
             national: FALLBACK_STATE_ASSOCIATION_SHORT_NAME)
      .to_a

    # Vereine ohne Landesverband gehören zum Bundesverband. Fehlt der, bleibt
    # ihr nil-Schlüssel stehen und sie landen unten in der Restgruppe.
    fallback = associations.find { |sa| sa.short_name == FALLBACK_STATE_ASSOCIATION_SHORT_NAME }
    if fallback && grouped.key?(nil)
      grouped[fallback.id] = (grouped[fallback.id] || []) + grouped.delete(nil)
    end

    groups = build_state_association_groups(grouped, associations, go_state_association_ids)

    # Vereine, deren Verweis ins Leere zeigt (gelöschter Landesverband, fehlender
    # Bundesverband), gehen nicht verloren, sondern kommen in eine namentlich
    # klare Restgruppe.
    known_ids = associations.map(&:id)
    orphans = grouped.reject { |sa_id, _| known_ids.include?(sa_id) }.values.flatten
    if orphans.any?
      log_unresolvable_state_associations(orphans, fallback)
      groups << orphan_group(orphans)
    end

    groups
  end

  def self.build_state_association_groups(grouped, associations, go_state_association_ids)
    groups = associations.filter_map do |sa|
      sa_clubs = grouped[sa.id] || []
      next if sa_clubs.empty? && !show_empty_state_association?(sa, associations, go_state_association_ids)

      state_association_group(sa, sa_clubs)
    end

    groups.sort_by { |g| g[:name] }
  end

  # Ein leerer Landesverband wird gezeigt, wenn er zu einem Spielbetrieb des
  # Nutzers gehört – als eigener Verband oder als dessen Unterverband.
  #
  # Verbände mit Unterverbänden bleiben außen vor: sie verwalten keine Vereine,
  # das Bearbeiten-Formular bietet nur Blatt-Verbände an (die API erzwingt das
  # nicht). Für „SBK Ost" erscheint deshalb keine leere Gruppe, sondern je eine
  # für Sachsen, Sachsen-Anhalt und Thüringen. Sind dem Dachverband aus Altdaten
  # doch noch Vereine zugeordnet, entsteht seine Gruppe weiter über diese
  # Vereine – die Prüfung greift nur für leere Gruppen.
  #
  # Die Prüfung auf Unterverbände steht bewusst vor beiden Treffern, damit sie
  # auch für einen Verband mittlerer Ebene gilt. StateAssociation erlaubt
  # beliebige Tiefe, auch wenn heute nur zwei Ebenen vorkommen.
  def self.show_empty_state_association?(state_association, associations, go_state_association_ids)
    return false if associations.any? { |other| other.parent_id == state_association.id }

    go_state_association_ids.include?(state_association.id) ||
      go_state_association_ids.include?(state_association.parent_id)
  end

  # Ein ins Leere zeigender Landesverband ist ein Datenfehler: auf
  # clubs.state_association_id liegt kein Fremdschlüssel, die Zuordnung kann
  # also auf einen gelöschten Verband verweisen. Ohne Log bliebe das
  # unbemerkt, weil die Restgruppe in der Oberfläche unauffällig aussieht.
  def self.log_unresolvable_state_associations(orphans, fallback)
    if fallback.nil?
      Rails.logger.error(
        'Club.admin_user_clubs: kein Landesverband mit short_name ' \
        "#{FALLBACK_STATE_ASSOCIATION_SHORT_NAME} gefunden – " \
        "#{orphans.count { |c| c.state_association_id.nil? }} Verein(e) ohne Landesverband " \
        'stehen unter „Ohne Landesverband" statt beim Bundesverband.'
      )
    end

    dangling = orphans.reject { |c| c.state_association_id.nil? }
    return if dangling.empty?

    liste = dangling.map { |c| "#{c.id}->#{c.state_association_id}" }.join(', ')
    Rails.logger.error(
      "Club.admin_user_clubs: Vereine verweisen auf nicht vorhandene Landesverbände: #{liste}"
    )
  end

  # Freigegebene Landesverbände (StateAssociationRelease) bleiben ein eigener,
  # lesend markierter Block – damit erkennbar bleibt, wem der Verein gehört.
  # Bereits oben gezeigte Vereine werden ausgelassen, damit derselbe Verein nicht
  # zweimal auf der Seite steht.
  def self.released_state_association_groups(go_ids, club_scope, shown_club_ids)
    released_sa_ids = StateAssociationRelease
      .current_season
      .where(recipient_game_operation_id: go_ids)
      .pluck(:grantor_state_association_id)

    StateAssociation.includes(logo_attachment: :blob).where(id: released_sa_ids).order(:name)
      .filter_map do |sa|
        released_clubs = club_scope.includes(logo_attachment: :blob)
          .where(state_association_id: sa.id)
          .where.not(id: shown_club_ids)
          .order(:name)
          .to_a
        next if released_clubs.empty?

        state_association_group(sa, released_clubs, released: true)
      end
  end

  # Eigene Vereine (VM-Rolle) ergänzen, soweit sie nicht schon über einen
  # Spielbetrieb oder eine Freigabe abgedeckt sind. Ohne das fehlten einem
  # Nutzer mit Admin-/SBK- *und* VM-Rolle genau die Vereine außerhalb seines
  # Spielbetriebs.
  def self.own_clubs_group(permission_hash, club_scope, covered_club_ids)
    own_clubs = club_scope.includes(logo_attachment: :blob)
      .where(id: permission_hash[:vm].to_a - covered_club_ids)
      .order(:name)
      .to_a
    return nil if own_clubs.empty?

    club_group(name: 'Eigene Vereine', clubs: own_clubs)
  end

  def self.state_association_group(state_association, clubs, released: false)
    # strip: einige Verbandsnamen tragen in Produktion ein führendes Leerzeichen,
    # das sonst in der Überschrift landet und die Sortierung verdreht.
    name = state_association.name.strip

    club_group(
      name: released ? "#{name} (freigegeben)" : name,
      clubs:,
      short_name: state_association.short_name,
      logo_url: state_association.logo_url,
      state_association_id: state_association.id,
      released:
    )
  end

  def self.orphan_group(clubs)
    club_group(name: 'Ohne Landesverband', clubs:)
  end

  # Gemeinsame Form aller Gruppen der Vereinsverwaltung.
  #
  # Anders als früher steckt hier kein GameOperation#meta_hash mehr: `id`, `path`,
  # `banner_url` und `logo_quad_url` sind entfallen. Sie beschrieben einen
  # Spielbetrieb, den eine Landesverbands-Gruppe nicht hat; `logo_quad_url` ist
  # mit den Spalten aus game_operations schon entfernt worden (siehe
  # game_operation_test.rb). Das Frontend liest keines der Felder.
  def self.club_group(name:, clubs:, short_name: nil, logo_url: nil,
                      state_association_id: nil, released: false)
    {
      name:,
      short_name:,
      logo_url:,
      state_association_id:,
      released:,
      clubs: clubs.map(&:full_hash)
    }
  end

  def add_logo(force = false)
    return if !force && logo.attached?

    dir = Dir["tmp/logovereine/#{id}*.png"]
    return unless dir.present?

    path = dir.first
    filename = path.split('/').last

    logo.attach(io: File.open(path), filename:, content_type: 'image/png')
  end

  def self.add_logos
    Club.all.each do |club|
      club.add_logo
    end
  end
end
