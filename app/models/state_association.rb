class StateAssociation < ApplicationRecord
  # Der Block „Einstellungen" der Verbandsmaske. Bei einem untergeordneten
  # Landesverband kommen diese Werte vollstaendig vom uebergeordneten Verbund:
  # gelesen ueber die effective_*-Methoden weiter unten, beim Speichern vom
  # Admin::StateAssociationsController verworfen.
  #
  # Nicht dabei und bewusst weiterhin eigene Daten des Kind-LV: die Postfaecher
  # (eigene Vererbung mit Rueckfall, siehe effective_vsk_email), der
  # Zustaendigkeitsbereich (vererbt in die andere Richtung, siehe
  # effective_states), Stammdaten, Logo, Banner, Spieltagscheckliste und
  # Freigaben.
  INHERITED_SETTINGS = %i[
    express_license_enabled
    referee_license_review_enabled
    scan_required
    referee_assignment_external_enabled
    referee_assignment_enabled
    person_level_assignment_default
    report_form_email_enabled
    manual_proceeding_creation
  ].freeze

  belongs_to :parent, class_name: 'StateAssociation', optional: true
  has_many :children, class_name: 'StateAssociation', foreign_key: :parent_id, dependent: :nullify
  has_many :checklist_items, class_name: 'StateAssociationChecklistItem', dependent: :destroy
  has_many :releases, class_name: 'StateAssociationRelease', foreign_key: :grantor_state_association_id,
                      dependent: :destroy
  has_one_attached :logo
  has_one_attached :banner

  validates :name, presence: true
  validate :parent_must_not_create_cycle
  validate :states_must_be_known
  before_validation :normalize_states

  after_commit { Current.reset_association_structure }

  # Der Verbandsbaum, aus dem sich die Zustaendigkeit fuer Vereine ableitet
  # (Club#main_game_operation_id). Einmal je Request aufgeloest statt je Verein:
  # Die Vereinsliste, die Rollenvergabe und die Transferpruefung laufen ueber den
  # ganzen Vereinsbestand, und eine Kette je Verein waere dort eine Abfrage je
  # Verein.
  #
  # Zwischengespeichert in Current und nicht in Rails.cache, Begruendung dort.
  #
  # { roots: { sa_id => Wurzel-sa_id }, subtrees: { Wurzel-sa_id => [sa_id, ...] } }
  def self.tree
    Current.state_association_tree ||= build_tree
  end

  # Iterativ mit `seen`, aus demselben Grund wie effective_states: gegen einen
  # Ringverweis aus der Zeit vor parent_must_not_create_cycle. Ein Verband in
  # einem Ring wird sein eigener Spielverbund, damit er nicht ganz aus den
  # Listen faellt.
  #
  # `parents.key?(up)` faengt einen Verweis auf einen geloeschten Verband ab:
  # auf state_associations.parent_id liegt kein Fremdschluessel. Ohne die
  # Pruefung waere die Wurzel eine ID, die es nicht gibt, und alle Vereine
  # darunter haetten lautlos keinen zustaendigen Spielbetrieb mehr. So bleibt
  # der letzte bekannte Verband die Wurzel.
  def self.build_tree
    parents = pluck(:id, :parent_id).to_h
    roots = parents.keys.index_with do |id|
      seen = []
      node = id
      while (up = parents[node]) && parents.key?(up) && !seen.include?(node)
        seen << node
        node = up
      end
      node
    end

    { roots:, subtrees: roots.keys.group_by { |id| roots[id] } }
  end

  # Der Spielverbund eines Landesverbands: er selbst, wenn er parentlos ist,
  # sonst die Wurzel seiner Kette. Fuer Sachsen, Sachsen-Anhalt und Thueringen
  # also SBK Ost.
  def self.root_id(id)
    return nil if id.blank?

    tree[:roots][id.to_i]
  end

  # Alle Landesverbaende, deren Spielverbund einer der uebergebenen ist,
  # einschliesslich der Wurzeln selbst. Das ist die Menge, fuer die der
  # Spielbetrieb dieses Verbunds zustaendig ist.
  def self.ids_under(root_ids)
    subtrees = tree[:subtrees]
    Array(root_ids).compact.map(&:to_i).flat_map { |root| subtrees[root] || [] }.uniq
  end

  # Bundeslaender, fuer die dieser Verband zustaendig ist, einschliesslich der
  # Bundeslaender seiner untergeordneten Verbaende.
  #
  # Vererbungsrichtung ist hier bewusst umgekehrt zu allen effective_*-Methoden
  # weiter unten: ein uebergeordneter Spielverbund (SBK Ost) betreut den Bereich
  # seiner Kinder mit, waehrend Postfaecher und Flags vom Kind nach oben
  # nachfragen. Deshalb wird nach unten gesammelt und nicht nach oben gelesen.
  #
  # Iterativ mit `seen`: parent_must_not_create_cycle haelt Ringverweise aus dem
  # Bestand heraus, aber an dieser Methode wird ab #468 eine Berechtigung
  # haengen, und ein Ringverweis aus der Zeit vor der Validierung wuerde sie in
  # eine Endlosschleife schicken statt in eine Fehlermeldung.
  #
  # Eine Abfrage je Knoten. Bei rund 15 Verbaenden und einem full_hash je Request
  # ohne Belang; der Aufrufer aus #468 prueft dagegen je Spielort und muss das
  # Ergebnis einmal vorhalten, statt den Baum pro Arena neu abzulaufen.
  def effective_states
    collected = []
    seen = []
    queue = [self]
    while (node = queue.shift)
      next if seen.include?(node.id)

      seen << node.id
      collected.concat(node.states.to_a)
      queue.concat(node.children.to_a)
    end
    # `compact` gegen Altbestand: die Spalte ist `null: false` und die Elemente
    # sind validiert, aber update_column und insert_all umgehen beides.
    collected.compact.uniq.sort
  end

  # Ist dieser Verband fuer das Bundesland zustaendig?
  #
  # Noch ohne Aufrufer: die Berechtigungspruefung am Spielort kommt als eigener
  # PR zu #468. Nicht loeschen, sondern dort verwenden.
  #
  # Das Argument wird normalisiert, weil es von aussen kommt und nicht aus
  # `states`: `clubs.state` ist ein freies Textfeld (der Controller permittet es
  # ungeprueft, eine Inclusion-Validierung gibt es nicht), und was die
  # Altdaten-Importe dort hineingeschrieben haben, weiss niemand. Ein `DE-NW` aus
  # so einer Quelle wuerde den NWFV sonst stumm von seinen eigenen Spielorten
  # aussperren, und der Rueckfall saehe genau aus wie „Bundesland noch nicht
  # gepflegt".
  #
  # Leeres Bundesland ist nie zustaendig. Das folgt zwar schon aus dem Inhalt von
  # `states`, steht hier aber ausdruecklich: fuer Spielorte ohne brauchbare PLZ
  # ist es die zugesicherte Eigenschaft, auf die #468 den Rueckfall auf den
  # Bundesverband stuetzt.
  def covers_state?(state)
    normalized = state.to_s.strip.downcase
    return false if normalized.blank?

    effective_states.include?(normalized)
  end

  # Der Landesverband, an dem die Einstellungen tatsaechlich gepflegt werden:
  # der eigene, und bei einem untergeordneten LV die Wurzel der Verbundskette.
  #
  # Ueber `self.class.root_id` und damit ueber denselben zwischengespeicherten
  # Baum wie `Club#main_game_operation_id`, statt die `parent`-Kette selbst
  # hochzulaufen. Drei Gruende: Der Baum wird einmal je Request aufgeloest (die
  # Rechtepruefung beim Login fragt fuer jeden Verband des Nutzers), er faengt
  # einen Verweis auf einen geloeschten Verband ab (auf `parent_id` liegt kein
  # Fremdschluessel), und er behandelt einen Ringverweis aus der Zeit vor
  # `parent_must_not_create_cycle` wie build_tree es tut, statt mit einer
  # zweiten, moeglicherweise abweichenden Regel.
  #
  # `id.nil?` faengt den noch nicht gespeicherten Datensatz beim Anlegen ab, und
  # ein `root == id` spart die Abfrage fuer den Regelfall ohne Verbund.
  def settings_source
    root = id && self.class.root_id(id)
    return self if root.nil? || root == id

    self.class.find_by(id: root) || self
  end

  # Ein Wert aus dem Block „Einstellungen" der Verbandsmaske, inklusive
  # Vererbung. Fuer jeden Schluessel aus INHERITED_SETTINGS gibt es unten eine
  # eigene Methode, damit die Aufrufer greppbar bleiben.
  def effective_setting(name)
    settings_source.public_send(name)
  end

  def effective_express_license_enabled
    effective_setting(:express_license_enabled)
  end

  # Der Kontrollprozess wird vom uebergeordneten LV kontrolliert: Der
  # Schiedsrichter-Kursergebnis-Import laeuft dort. Tests in
  # referee_course_submit_policy_test.rb verankern diese Semantik.
  def effective_referee_license_review_enabled
    effective_setting(:referee_license_review_enabled)
  end

  def effective_scan_required
    effective_setting(:scan_required)
  end

  def effective_referee_assignment_external_enabled
    effective_setting(:referee_assignment_external_enabled)
  end

  def effective_referee_assignment_enabled
    effective_setting(:referee_assignment_enabled)
  end

  def effective_person_level_assignment_default
    effective_setting(:person_level_assignment_default)
  end

  def effective_report_form_email_enabled
    effective_setting(:report_form_email_enabled)
  end

  def effective_manual_proceeding_creation
    effective_setting(:manual_proceeding_creation)
  end

  # Postfach für Schiedsrichteransetzungen. Ohne eigenen Eintrag greift der
  # übergeordnete Verband (Floorball Deutschland pflegt dort die zentrale
  # Adresse), damit Anträge nirgends ins Leere laufen.
  def effective_rsk_email
    rsk_email.presence || parent&.effective_rsk_email
  end

  # Wie effective_rsk_email: Postfächer eines untergeordneten Landesverbands
  # fallen auf den übergeordneten Verbund zurück, und zwar über die ganze Kette
  # bis zur Wurzel. Anders als bei den Einstellungen (settings_source oben) ist
  # das ein Rückfall und keine Übernahme: ein eigener Eintrag am Kind-LV gewinnt,
  # gesperrt ist das Feld nur, solange keiner gepflegt ist. Nötig, weil das
  # Formular die Felder bei Kind-LVs
  # sperrt und als „geerbt" ausweist, beim Speichern sogar nil mitschickt.
  #
  # Ohne Rückfall lasen alle Mailer die Adresse direkt am Kind-Datensatz: bei
  # Transfers über den Verein (former_club.state_association), bei Spieltags-,
  # Expresslizenz- und Berichtsmails über den Spielbetrieb der Liga. Wo ein
  # früher return am leeren Feld hing, verschwand die Mail lautlos.
  def effective_vsk_email
    vsk_email.presence || parent&.effective_vsk_email
  end

  # Siehe effective_vsk_email.
  def effective_sbk_email
    sbk_email.presence || parent&.effective_sbk_email
  end

  # Ansetzungsmodus des Landesverbands – die *einzige* Stelle, die die drei
  # gestaffelten Schalter auswertet. Die Maske graut Option 2 und 3 aus, solange
  # der Hauptschalter aus ist; darauf darf sich der Server aber nicht verlassen
  # (API-Aufrufe umgehen die Maske, und ein nachträglich abgeschalteter
  # Hauptschalter lässt ein `referee_assignment_enabled = true` im Datensatz
  # zurück). Deshalb hier ausgewertet und nicht an den Feldern selbst.
  #
  # Gelesen wird an `settings_source`, nicht am eigenen Datensatz: bei einem
  # untergeordneten Landesverband bestimmt der übergeordnete Verbund, auf welchem
  # Weg angesetzt wird. Ein Kind-LV hat die drei Schalter gar nicht mehr in der
  # Maske, sein gespeicherter Stand ist damit nur noch ein Überbleibsel.
  #
  #   :none   – nur die SBK setzt an (Weg 1, Freitext am Spiel)
  #   :club   – RSK pflegt Verein oder Freitext (Weg 3, reduzierte Ansicht)
  #   :person – Ansetzer-Rolle setzt personenscharf an (Weg 2)
  #
  # Die Personenebene gewinnt: sie schließt den reduzierten Modus aus, damit
  # nicht zwei Wege dasselbe Spiel bearbeiten.
  def referee_assignment_mode
    source = settings_source
    return :none unless source.referee_assignment_external_enabled?
    return :person if source.referee_assignment_enabled?

    :club
  end

  # Weg 2 (personenscharfe Ansetzung durch die Ansetzer-Rolle) ist aktiv.
  def person_level_assignment_active?
    referee_assignment_mode == :person
  end

  # Weg 3 (reduzierte RSK-Ansicht: Verein oder Freitext) ist aktiv.
  def club_level_assignment_active?
    referee_assignment_mode == :club
  end

  def logo_url
    Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true) if logo.attached?
  end

  def banner_url
    Rails.application.routes.url_helpers.rails_blob_path(banner, only_path: true) if banner.attached?
  end

  def short_hash
    { id:, name:, short_name:, parent_id:, logo_url:, banner_url:, banner_link_url: }
  end

  # season_id (optional): Blickt in die Freigaben einer vergangenen Saison
  # zurück. Ohne Param bleibt der Default die aktuelle Saison – damit eine
  # künftige Saisonenauswahl in der UI auch historische Audit-Einträge zeigen
  # kann (siehe Issue #191).
  def full_hash(season_id: nil)
    release_scope = season_id.present? ? releases.where(season_id:) : releases.current_season
    {
      id:,
      name:,
      short_name:,
      scan_required:,
      vsk_email:,
      sbk_email:,
      rsk_email:,
      parent_id:,
      parent_name: parent&.name,
      states:,
      # Der tatsaechlich greifende Bereich inklusive der untergeordneten
      # Verbaende. Die Maske zeigt beides: eigene Auswahl zum Bearbeiten, den
      # geerbten Rest als Hinweis (bei einem Spielverbund ist das eigene Feld
      # ueblicherweise leer und der Bereich kommt komplett von den Kindern).
      effective_states:,
      express_license_enabled:,
      referee_license_review_enabled:,
      # Die tatsächlich greifenden Werte mitliefern, damit die Verbandsmaske bei
      # einem untergeordneten LV nicht dessen eigenen (überbleibenden) Wert
      # anzeigt. Der Listen-Endpunkt liefert nur short_hash, ohne Postfächer und
      # Flags, das Formular kann sie also nicht aus dem Parent-Datensatz lesen.
      #
      # Einstellungen und Postfächer erben unterschiedlich, siehe die Methoden
      # oben: die Einstellungen kommen bei gesetztem Verbund vollständig von der
      # Wurzel der Kette (settings_source), die Postfächer sind ein Rückfall und
      # weichen einem eigenen Eintrag. `.present?` normalisiert ein mögliches nil
      # aus dem Altbestand auf false, damit die Maske keine Checkbox mit
      # `undefined` befüllt.
      effective_express_license_enabled: effective_express_license_enabled.present?,
      effective_referee_license_review_enabled: effective_referee_license_review_enabled.present?,
      effective_scan_required: effective_scan_required.present?,
      effective_referee_assignment_external_enabled: effective_referee_assignment_external_enabled.present?,
      effective_referee_assignment_enabled: effective_referee_assignment_enabled.present?,
      effective_person_level_assignment_default: effective_person_level_assignment_default.present?,
      effective_report_form_email_enabled: effective_report_form_email_enabled.present?,
      effective_manual_proceeding_creation: effective_manual_proceeding_creation.present?,
      effective_vsk_email:,
      effective_sbk_email:,
      effective_rsk_email:,
      manual_proceeding_creation:,
      # Die drei gestaffelten Ansetzungs-Schalter. `referee_assignment_enabled`
      # heißt in der Maske jetzt „Ansetzungen auf Personenebene"; der
      # Spaltenname bleibt, um den Bestand nicht anzufassen.
      referee_assignment_external_enabled:,
      referee_assignment_enabled:,
      person_level_assignment_default:,
      report_form_email_enabled:,
      logo_url:,
      banner_url:,
      banner_link_url:,
      children: children.order(:name).map(&:short_hash),
      checklist_items: checklist_items.map { |i| { id: i.id, question: i.question, position: i.position } },
      releases: release_scope.includes(:recipient_game_operation).map do |r|
        {
          id: r.id,
          recipient_game_operation_id: r.recipient_game_operation_id,
          recipient_game_operation_name: r.recipient_game_operation.name,
          season_id: r.season_id
        }
      end
    }
  end

  private

  # Schreibweise, Dubletten und Reihenfolge vereinheitlichen. Im Modell und nicht
  # im Controller, weil sonst die halbe Invariante dort und die andere Haelfte
  # hier stuende: states_must_be_known lehnt einen leeren String und ein `DE-NW`
  # ab, der Controller waescht beides vorher weg – die Waesche existiert also nur,
  # weil das Modell streng ist. So halten Rake-Task, Konsole und Seed dieselbe
  # Invariante wie die Maske. Gleiches Muster wie normalize_user_name (user.rb).
  #
  # `Array(states)` faengt nebenbei ein ausdrueckliches nil ab, das sonst erst
  # als NotNullViolation aus der Datenbank kaeme statt als Feldfehler.
  def normalize_states
    self.states = Array(states).map { |code| code.to_s.strip.downcase }.reject(&:blank?).uniq.sort
  end

  # Nur die 16 echten Bundeslaender, und zwar gegen dieselbe Quelle wie die
  # Ableitung am Spielort (ApplicationRecord.german_states). Ein Tippfehler im
  # Kuerzel wuerde sonst als „Verband ist fuer nichts zustaendig" durchgehen: die
  # Pruefung faellt still auf den Bundesverband zurueck, es gibt also keine
  # Fehlermeldung, an der es auffiele.
  #
  # `de-sonstige` ist bewusst nicht erlaubt. Der Wert existiert in der
  # Vereinsmaske fuer Vereine mit Sitz im Ausland; ein Zustaendigkeitsbereich
  # „Sonstige" ergibt dagegen keinen Sinn.
  def states_must_be_known
    unknown = states.to_a.compact - ApplicationRecord.german_states
    return if unknown.empty?

    errors.add(:states, "enthaelt unbekannte Bundeslaender: #{unknown.join(', ')}")
  end

  # Die Verbandsmaske bietet als übergeordneten Verbund nur parentlose LVs an
  # und schließt den eigenen aus, per API ist parent_id aber ungeprüft. Ein
  # Selbst- oder Ringverweis würde die Postfach-Vererbung (effective_vsk_email
  # und Geschwister laufen bis zur Wurzel) in eine Endlosrekursion schicken und
  # damit auch full_hash reißen, also genau die Maske, mit der man den Verweis
  # zurücknehmen würde.
  def parent_must_not_create_cycle
    return if parent_id.blank?

    if parent_id == id
      errors.add(:parent_id, 'kann nicht der eigene Landesverband sein')
      return
    end

    seen = [id].compact
    node = parent
    while node
      return errors.add(:parent_id, 'erzeugt einen Ringverweis in der Verbandshierarchie') if seen.include?(node.id)

      seen << node.id
      node = node.parent
    end
  end
end
