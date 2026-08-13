class StateAssociation < ApplicationRecord
  belongs_to :parent, class_name: 'StateAssociation', optional: true
  has_many :children, class_name: 'StateAssociation', foreign_key: :parent_id, dependent: :nullify
  has_many :checklist_items, class_name: 'StateAssociationChecklistItem', dependent: :destroy
  has_many :releases, class_name: 'StateAssociationRelease', foreign_key: :grantor_state_association_id,
                      dependent: :destroy
  has_one_attached :logo
  has_one_attached :banner

  validates :name, presence: true
  validate :parent_must_not_create_cycle

  def effective_express_license_enabled
    express_license_enabled || parent&.express_license_enabled
  end

  # Abweichende Semantik zu effective_express_license_enabled (oben): Parent-LV
  # dominiert; das eigene Flag wird ignoriert, sobald ein Parent gesetzt ist.
  # Hintergrund: Der Schiedsrichter-Kursergebnis-Import wird vom uebergeordneten
  # LV kontrolliert. StateAssociationsController erzwingt zusaetzlich
  # referee_license_review_enabled = false fuer Kinder-LVs, damit dieses Feld
  # nicht aus Versehen lokal gesetzt wird. Tests in
  # referee_course_submit_policy_test.rb verankern diese Semantik.
  def effective_referee_license_review_enabled
    return parent.referee_license_review_enabled if parent

    referee_license_review_enabled
  end

  # Postfach für Schiedsrichteransetzungen. Ohne eigenen Eintrag greift der
  # übergeordnete Verband (Floorball Deutschland pflegt dort die zentrale
  # Adresse), damit Anträge nirgends ins Leere laufen.
  def effective_rsk_email
    rsk_email.presence || parent&.effective_rsk_email
  end

  # Wie effective_rsk_email: Postfächer eines untergeordneten Landesverbands
  # fallen auf den übergeordneten Verbund zurück, und zwar über die ganze Kette
  # bis zur Wurzel (anders als effective_express_license_enabled oben, das nur
  # eine Ebene hochschaut). Nötig, weil das Formular die Felder bei Kind-LVs
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
  #   :none   – nur die SBK setzt an (Weg 1, Freitext am Spiel)
  #   :club   – RSK pflegt Verein oder Freitext (Weg 3, reduzierte Ansicht)
  #   :person – Ansetzer-Rolle setzt personenscharf an (Weg 2)
  #
  # Die Personenebene gewinnt: sie schließt den reduzierten Modus aus, damit
  # nicht zwei Wege dasselbe Spiel bearbeiten.
  def referee_assignment_mode
    return :none unless referee_assignment_external_enabled?
    return :person if referee_assignment_enabled?

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

  # Neue Spiele gleich für die Personenebene markieren. Nur wirksam, wenn die
  # Personenebene überhaupt greift – sonst entstünden Spiele, die in keiner
  # Ansicht bearbeitbar sind (der reduzierte Modus sperrt markierte Spiele).
  def person_level_assignment_default_active?
    person_level_assignment_active? && person_level_assignment_default?
  end

  # Nationaler Spielbetrieb (FD, ohne Landesverband) bleibt wie bisher immer auf
  # der Personenebene. `state_association` ist dort nil, deshalb kann kein
  # Datensatz gefragt werden – die Aufrufer nutzen diese Konstanten-Methoden, um
  # den Sonderfall an einer Stelle zu halten.
  def self.national_referee_assignment_mode
    :person
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
      express_license_enabled:,
      referee_license_review_enabled:,
      effective_referee_license_review_enabled:,
      # Die tatsächlich greifenden Werte mitliefern, damit die Verbandsmaske bei
      # einem untergeordneten LV nicht dessen eigenen (leeren) Wert anzeigt. Der
      # Listen-Endpunkt liefert nur short_hash, ohne Postfächer und Flags, das
      # Formular kann sie also nicht aus dem Parent-Datensatz lesen.
      #
      # Die drei Vererbungsarten unterscheiden sich, siehe die Methoden oben:
      # express_license schaut eine Ebene hoch und liest dort das eigene Feld des
      # Parents, referee_license_review wird vom Parent komplett bestimmt, die
      # Postfächer laufen bis zur Wurzel. .present? normalisiert das mögliche nil
      # aus dem ||-Ausdruck auf false.
      effective_express_license_enabled: effective_express_license_enabled.present?,
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
