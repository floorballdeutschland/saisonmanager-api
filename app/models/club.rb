class Club < ApplicationRecord
  has_many :game_days
  belongs_to :state_association, optional: true

  has_one_attached :logo

  # Das Kürzel ist ein Anzeigezeichen, kein Name: Es steht auf der
  # Anzeigetafel des Livestreams, wo mehr als vier Zeichen die Bauchbinde
  # sprengen. Bestandswerte sind länger, deshalb nur beim Speichern geprüft
  # und Leerwerte erlaubt (das Feld ist nullable).
  SHORT_NAME_MAX = 4

  # `if:` statt unbedingt: Bestandswerte sind länger, und eine unbedingte
  # Prüfung hätte jedes Speichern dieser Vereine blockiert – auch das
  # Deaktivieren und Reaktivieren (`deactivate!`/`reactivate!`), das in einer
  # Maske ohne Kürzel-Feld an einer Meldung über das Kürzel gescheitert wäre.
  # Für die Vereine, deren Kürzel beim Kürzen kollidiert und deshalb stehen
  # bleibt, wäre das dauerhaft so geblieben.
  validates :short_name, length: { maximum: SHORT_NAME_MAX },
                         allow_blank: true, if: :short_name_changed?

  # Eine Adresse, nicht mehrere. Auf Produktion trug ein Verein zwei Adressen
  # mit Semikolon getrennt im Feld – beide bekamen nie etwas, weil das Feld als
  # eine Adresse verschickt wird. Wer mehrere Empfänger braucht, lässt die
  # Vereinsmanager mitlaufen (siehe notify_managers).
  EMAIL_FORMAT = /\A[^@\s;,]+@[^@\s;,]+\.[^@\s;,]+\z/

  # `if:` statt unbedingt: Auf Produktion trägt ein Verein bereits zwei
  # Adressen im Feld. Eine unbedingte Prüfung hätte jedes Speichern dieses
  # Vereins blockiert – auch das Deaktivieren (`deactivate!` nutzt `update!`)
  # und die Liga-Kopie, die Vereine mitschreibt. Wer die Adresse anfasst, muss
  # die Regel einhalten; wer sie nicht anfasst, wird nicht aufgehalten.
  validates :contact_email, format: { with: EMAIL_FORMAT },
                            allow_blank: true, if: :contact_email_changed?

  scope :active, -> { where(deactivated_at: nil) }

  # Vereinsmanager dieses Vereins. Kandidaten per jsonb-Containment vorfiltern
  # und dann über permission_hash bestätigen, das allein die Sonderfälle kennt
  # (Mehrfachrollen, Alt-Einträge).
  #
  # Beide Typvarianten abfragen, wie es admin/users_controller schon tut:
  # jsonb-Containment ist typstreng, `@> '[{"user_group_id":4}]'` findet einen
  # Alt-Eintrag mit `"4"` nicht. Das wäre ein stiller Fehler – der
  # Vereinsmanager fehlte einfach in der Auswahlliste, ohne Meldung.
  # `permission_hash` selbst nutzt `.to_i` und verträgt beides.
  def club_managers
    User.not_archived
        .where('permissions @> ? OR permissions @> ?',
               [{ user_group_id: 4 }].to_json,
               [{ user_group_id: '4' }].to_json)
        .select { |user| Array(user.permission_hash[:vm]).include?(id) }
  end

  # Alle Empfänger der Vereinspost: die Kontaktadresse plus die
  # Vereinsmanager, die nicht abgewählt sind.
  def notification_emails
    ([contact_email] + notify_manager_emails)
      .map { |mail| mail.to_s.strip }
      .reject(&:blank?)
      .uniq
  end

  # Der Verteiler wird bei jedem Versand aus den aktuellen Rechten gebildet,
  # nicht aus gespeicherten IDs. Wer die Rolle verliert, fällt damit von selbst
  # heraus; wer sie neu bekommt, ist von selbst dabei.
  def notify_manager_emails
    notify_managers.filter_map { |user| user.email.presence }
  end

  # Die Vereinsmanager, die Vereinspost bekommen: alle außer den abgewählten.
  def notify_managers
    excluded = notify_excluded_ids
    club_managers.reject { |user| excluded.include?(user.id) }
  end

  def notify_excluded_ids
    Array(notify_excluded_user_ids).map(&:to_i).to_set
  end

  # Nach außen bleibt es eine Auswahl: Die Maske hakt an, wer Post bekommt, und
  # schickt genau diese IDs zurück. Gespeichert wird die Gegenmenge, damit ein
  # später berufener Vereinsmanager ohne Zutun im Verteiler steht – er ist in
  # keiner Abwahl genannt. Eine gespeicherte Auswahl hätte ihn ausgeschlossen.
  def notify_user_ids
    notify_managers.map(&:id)
  end

  # Nur Vereinsmanager, die es zum Zeitpunkt des Speicherns gibt, können
  # abgewählt werden. Fremde oder erfundene IDs landen nicht in der Abwahl –
  # sonst hinge dort Müll, der einen später berufenen Vereinsmanager mit
  # derselben ID stillschweigend aus dem Verteiler nähme.
  def notify_user_ids=(ids)
    selected = Array(ids).map(&:to_i).to_set
    self.notify_excluded_user_ids = club_managers.map(&:id).reject { |id| selected.include?(id) }
  end

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
    p = scope.where('players.clubs @> ?', [{ club_id: id }].to_json).order(:last_name, :first_name)
    p.select do |pl|
      pl.clubs.map do |c|
        # Strukturell kaputter Eintrag (kein Objekt) aus dem Altbestand: zaehlt nicht als
        # Mitgliedschaft. Ohne den Riegel bricht die Vereinsspielerliste mit einem 500er ab,
        # sobald ein einziges Profil des Vereins so einen Eintrag traegt.
        if !c.is_a?(Hash)
          false
        elsif c['club_id'] != id
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

  # Ueber die je Request geladene Karte und nicht per find_by: Diese Methode
  # laeuft in den Lizenzlisten je Zeile (Player#create_license_hash).
  def home_game_operation
    GameOperation.by_id[main_game_operation_id]
  end

  # Der zustaendige Verband des Vereins: die Wurzel seiner Verbandskette. Fuer
  # einen Verein in Sachsen also SBK Ost, fuer einen in Hamburg dessen
  # Elternverband. In der Oberflaeche heisst dieser Wert „Spielverbund".
  def responsible_state_association_id
    StateAssociation.root_id(state_association_id)
  end

  # Derselbe Verband als Datensatz, fuer Texte, die ihn benennen muessen (die
  # Transfermails). `state_association` ist dort der falsche Wert: Genehmigen
  # darf der Verbund -- siehe main_game_operation_id -- und ein Kind-LV wie der
  # Floorball Bund Hamburg entscheidet ueber nichts.
  def responsible_state_association
    StateAssociation.find_by(id: responsible_state_association_id)
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

  # Der zustaendige Spielbetrieb, abgeleitet aus dem Landesverband des Vereins:
  # Landesverband, Wurzel der Verbandskette, Spielbetrieb dieser Wurzel.
  #
  # Frueher stand die Zuordnung als Heimat-Eintrag im `game_operations_hash` und
  # musste am Verein gepflegt werden, unabhaengig vom Landesverband. Damit gab es
  # zwei Felder fuer eine Frage, und sie liefen auseinander: Die Vereinsmaske
  # zeigt einen aus dem Landesverband abgeleiteten „Spielverbund", gespeichert
  # war aber ein davon unabhaengiger Spielbetrieb, und beim Bearbeiten war das
  # Feld nicht einmal sichtbar (nur die Neuanlage hatte es). So verwaltete
  # Floorball Niedersachsen den ETV Hamburg, waehrend die Maske Hamburg auswies,
  # und niemand konnte das ueber die Oberflaeche sehen oder aendern.
  #
  # Ein Verein ohne Landesverband hat keinen zustaendigen Spielbetrieb, ebenso
  # einer, dessen Verbund keinen Spielbetrieb hat. `nil` ist hier also ein
  # gueltiger Wert und bedeutet „niemand ist zustaendig". Wer diese Vereine zu
  # sehen bekommt, entscheidet .admin_user_clubs: nur der globale Zugriff, siehe
  # dort und Club.unassigned.
  def main_game_operation_id
    GameOperation.id_by_state_association[responsible_state_association_id]
  end

  # Darf ein Admin-/SBK-Scope diesen Verein LESEN? Genau zwei Gründe:
  # der zuständige Spielbetrieb des Vereins, oder eine aktuelle Vereins-Freigabe
  # (StateAssociationRelease) des Landesverbands, dem der Verein gehört.
  #
  # Beide Zweige lesen jetzt dasselbe Feld: der erste über die abgeleitete
  # Zuständigkeit, der zweite über den Landesverband selbst. Vorher kam der eine
  # aus `game_operations_hash` und der andere aus `state_association_id`, sie
  # konnten sich also widersprechen.
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

    vm = ph[:vm].present? && ph[:vm].include?(id)

    perm << :update_club if admin || sbk
    perm << :update_player if admin || sbk

    # Bewusst getrennt von :update_club. Der Vereinsmanager pflegt die
    # Stammdaten seines eigenen Vereins, darf aber weder die Einordnung
    # (Bundesland, Landesverband, Spielbetrieb) ändern noch den Verein
    # deaktivieren. Beides hängt an :update_club – deaktivieren würde sich
    # der Verein sonst selbst.
    perm << :update_own_club if admin || sbk || vm

    # Die Anlage hängt am Verein, nicht an der Mannschaft: Der neue Eintrag
    # wird als Heimatmitgliedschaft dieses Vereins geführt, eine
    # Kaderzuordnung entsteht nicht. Wer in den Verein aufgenommen wird,
    # entscheidet deshalb der Vereinsmanager. Teammanager*innen hatten das
    # Recht bis api#530 ebenfalls; sie stellen weiter auf und melden Lizenzen
    # an, den Neuzugang legt der Verein an. Stammdaten
    # nachträglich ändern (`:update_player`) darf unverändert nur der Verband.
    perm << :create_player if admin || sbk || vm

    perm
  end

  # Vereine, für die der User vereinsgebundene Rollen (VM/TM) vergeben darf:
  # die eigenen VM-Vereine plus die Vereine der eigenen SBK-Spielbetriebe.
  #
  # Für die SBK-Rolle ist der zuständige Spielbetrieb des Vereins maßgeblich
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
    # Die SBK-Vereine per Query statt per Schleife über den ganzen Bestand: die
    # Zuständigkeit hängt jetzt an einer eigenen Spalte und muss nicht mehr je
    # Verein aus einem jsonb-Feld gelesen werden. Ein Index auf
    # `clubs.state_association_id` fehlt weiterhin; bei knapp 300 Vereinen ist der
    # Sequential Scan unkritisch.
    ids = Array(ph[:vm])
    ids += scope.merge(home_clubs_of(ph[:sbk])).pluck(:id) if ph[:sbk].present?

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

  # Gruppiert die Vereine nach ihrem eingestellten Landesverband
  # (clubs.state_association_id). Untergeordnete Landesverbände (Sachsen,
  # Sachsen-Anhalt, Thüringen) sind dadurch einzeln sichtbar statt gesammelt
  # unter „SBK Ost".
  #
  # Überschrift und Zugriff kommen jetzt aus demselben Feld: der Zugriff über den
  # Spielverbund (die Wurzel der Verbandskette, siehe
  # #main_game_operation_id), die Überschrift über den Landesverband selbst.
  # Beides kann sich also nicht mehr widersprechen. Vorher hing der Zugriff an
  # einem zweiten, am Verein gepflegten Feld, und ein Verein konnte unter der
  # Überschrift eines Verbands stehen, den ein völlig anderer verwaltete.
  #
  # Ein untergeordneter Verband behält damit seine eigene Gruppe, während der
  # Verbund darüber den Zugriff trägt: Die Hamburger Vereine stehen unter
  # „Floorball Bund Hamburg", verwaltet werden sie vom Spielbetrieb des
  # Verbunds, dem Hamburg untergeordnet ist.
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

    # Vereine ohne Landesverband nur für globalen Zugriff: für sie ist kein
    # Spielbetrieb zuständig, sie wären sonst unsichtbar und nicht bearbeitbar.
    # Ein einzelner Landesverband soll dafür aber nicht die unzugeordneten
    # Vereine aller anderen in seiner Liste haben.
    #
    # Auf Produktion waren das am 19.08.2026 vier Ablage-Vereine; der Datenlauf
    # zu dieser Umstellung ordnet sie dem Bundesverband zu, danach ist die Menge
    # regulär leer und der Zweig reine Vorsorge.
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

  # Vereine, für die die übergebenen Spielbetriebe zuständig sind: alle Vereine
  # in den Landesverbänden unter dem Spielverbund des jeweiligen Spielbetriebs.
  # Eine Query auf eine eigene Spalte statt der früheren jsonb-Bedingungen auf
  # `game_operations_hash`. Einen Index gibt es auf beiden Wegen nicht, bei knapp
  # 300 Vereinen ohne Belang; `Club.unassigned` (`NOT IN`) könnte ihn ohnehin
  # nicht nutzen.
  #
  # Nur der zuständige Verband verwaltet die Stammdaten eines Vereins. Fremde
  # Vereine erscheinen ausschließlich über eine Vereins-Freigabe, also im
  # „(freigegeben)"-Block.
  #
  # include_unassigned nimmt die Vereine mit, für die kein Spielbetrieb zuständig
  # ist. Sie wären sonst für niemanden sichtbar; ein einzelner Verband soll sie
  # aber nicht in seiner Liste haben, deshalb entscheidet der Aufrufer.
  def self.home_clubs_of(go_ids, include_unassigned: false)
    sa_ids = responsible_state_association_ids(go_ids)
    return include_unassigned ? unassigned : none if sa_ids.empty?
    return where(state_association_id: sa_ids) unless include_unassigned

    where(state_association_id: sa_ids).or(unassigned)
  end

  # Vereine, für die kein Spielbetrieb zuständig ist. Drei Gründe, und die beiden
  # letzten sind die unauffälligen:
  #
  # 1. kein Landesverband gesetzt (auf Produktion am 19.08.2026 vier
  #    Ablage-Vereine, die der Datenlauf zuordnet),
  # 2. ein Landesverband, den es nicht gibt – auf clubs.state_association_id liegt
  #    kein Fremdschlüssel, der Verweis kann ins Leere zeigen,
  # 3. ein Landesverband, dessen Verbund keinen Spielbetrieb hat. Genau dieser
  #    Fall hat die Umstellung ausgelöst: In der Maske steht ein Verband, und
  #    trotzdem ist niemand zuständig.
  #
  # Alle drei müssen mit, sonst verschwindet der Verein auch aus der Liste der
  # Bundesebene, also aus der einzigen, in der er zu reparieren ist. Er landet
  # dann über Club.group_by_state_association unter seinem Landesverband oder in
  # der Restgruppe „Ohne Landesverband".
  #
  # Formuliert als Gegenmenge der zugeordneten Verbände, damit alle drei Fälle
  # von einer Bedingung erfasst werden, statt sie einzeln aufzuzählen und dabei
  # einen zu übersehen.
  def self.unassigned
    zugeordnet = assigned_state_association_ids
    # `NOT IN ()` wäre ungültiges SQL, und Rails macht daraus ein `1=1`. Der Fall
    # ist deshalb ausdrücklich benannt: Gibt es keinen zuständigen Verband, ist
    # kein Verein zugeordnet.
    return all if zugeordnet.empty?

    where(state_association_id: nil).or(where.not(state_association_id: zugeordnet))
  end

  # Landesverbände, für die überhaupt ein Spielbetrieb zuständig ist. Löst die
  # beiden Karten einmal je Request auf; im globalen Zugriff ist diese Methode
  # sogar deren erster Verbraucher, die zwei Abfragen fallen also hier an (der
  # N+1-Test in club_test.rb zählt sie mit).
  def self.assigned_state_association_ids
    go_by_root = GameOperation.id_by_state_association
    StateAssociation.tree[:roots].select { |_, root| go_by_root.key?(root) }.keys
  end

  # Landesverbände, für die die übergebenen Spielbetriebe zuständig sind.
  #
  # Zwei Schritte, und tragend ist nur der zweite: Die Hebung auf die Wurzel
  # macht aus dem Landesverband des Spielbetriebs den Verbund und holt dessen
  # ganzen Teilbaum; der `select!` nimmt davon alles wieder weg, wofür dieser
  # Spielbetrieb nicht zuständig ist. Die Hebung allein ist also wirkungslos
  # (ohne sie liefert `ids_under` für einen Unterverband ohnehin nichts, weil
  # `subtrees` nur nach Wurzeln indiziert ist). Sie steht hier, weil sie die
  # Absicht lesbar macht: erst den Verbund bestimmen, dann prüfen, ob er uns
  # gehört.
  #
  # Der `select!` macht die Methode zur genauen Umkehrung von
  # #main_game_operation_id: Ein Verbund kommt nur mit, wenn die Zuständigkeit
  # für ihn tatsächlich bei einem der übergebenen Spielbetriebe liegt. Ohne diese
  # Bedingung genügte es, irgendwo unter der Wurzel zu hängen, und das fällt in
  # zwei erreichbaren Lagen auseinander:
  #
  #   1. Ein Spielbetrieb an einem UNTERGEORDNETEN Verband. Er bekäme den ganzen
  #      Teilbaum des Verbunds, obwohl #main_game_operation_id auf den
  #      Spielbetrieb des Verbunds zeigt. Genau das entsteht, sobald jemand nach
  #      #492 einen Spielbetrieb für Hamburg anlegt: Er hätte alle Vereine
  #      Schleswig-Holsteins in seiner Liste, mit Kontaktadresse.
  #   2. Zwei Spielbetriebe an einem Verband. `id_by_state_association` behält
  #      den mit der niedrigeren ID; der andere sähe den Teilbaum trotzdem.
  #
  # In beiden Fällen wären die Vereine gelistet, aber nicht bearbeitbar
  # (`Club#user_permissions` fragt #main_game_operation_id), und ihre
  # Spielerlisten antworteten leer. Also genau die Art stillen Widerspruchs, die
  # diese Umstellung beseitigen soll.
  def self.responsible_state_association_ids(go_ids)
    ids = Array(go_ids).compact.map(&:to_i).reject(&:zero?)
    return [] if ids.empty?

    go_by_root = GameOperation.id_by_state_association
    roots = GameOperation.where(id: ids).pluck(:state_association_id).compact
                         .map { |sa_id| StateAssociation.root_id(sa_id) }.compact.uniq
    roots.select! { |root| ids.include?(go_by_root[root]) }
    StateAssociation.ids_under(roots)
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
