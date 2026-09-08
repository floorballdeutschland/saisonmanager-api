class RefereeCourseResult < ApplicationRecord
  MATCH_TYPES = %w[exact_match partial_match new_entry].freeze
  STATUSES    = %w[pending_review applied rejected].freeze

  MASTER_FIELDS = %i[lizenznummer vorname nachname geburtsdatum club_id email].freeze
  CSV_FIELDS    = %i[lizenznummer vorname nachname geburtsdatum verein email].freeze

  belongs_to :referee_course_import
  belongs_to :referee, optional: true
  belongs_to :state_association, optional: true
  belongs_to :reviewed_by_user, class_name: 'User', optional: true

  validates :match_type, inclusion: { in: MATCH_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :match_field_count, numericality: { in: 0..6, only_integer: true }

  scope :pending_review,         -> { where(status: 'pending_review') }
  scope :applied,                -> { where(status: 'applied') }
  scope :rejected,               -> { where(status: 'rejected') }
  scope :for_state_associations, ->(ids) { where(state_association_id: ids) }

  # Die drei Lagen einer noch nicht eingereichten Zeile. `status` und
  # `submitted_at` muessen in allen dreien stehen: `pending_review` allein
  # traegt auch die beim LV wartenden Zeilen, und ohne den Statusfilter wuerde
  # ein zweiter Submit eine vom Importeur verworfene Zeile doch noch anwenden.
  #
  # Vom Importeur zurueckgestellt: wartet auf eine Klaerung ausserhalb des
  # Systems und wird beim Einreichen uebersprungen.
  scope :deferred,          -> { where(deferred: true, submitted_at: nil, status: 'pending_review') }
  # Die Zeilen, die ein Submit dieses Imports anwenden wuerde.
  scope :submittable,       -> { where(deferred: false, submitted_at: nil, status: 'pending_review') }
  # Alles, was der Importeur noch in der Hand hat -- einreichbar oder
  # zurueckgestellt. Daran haengt, ob ein Import abgeschlossen ist.
  scope :open_for_importer, -> { where(submitted_at: nil, status: 'pending_review') }

  # Nur eingereichte Zeilen warten wirklich auf die LV-Freigabe. Der
  # Import-Service legt JEDE Zeile sofort beim Upload mit `pending_review` an --
  # der Zeilenstatus allein trennt die Importeurs-Vorschau also nicht von der
  # Freigabe-Warteschlange.
  #
  # Das Merkmal ist `submitted_at` und nicht der Import-Status: Seit dem
  # zeilenweisen Einreichen enthaelt ein Import auf `partially_submitted` beides
  # -- wartende und noch gar nicht eingereichte (zurueckgestellte) Zeilen.
  # Abgebrochene Importe bleiben ausgeschlossen; deren Zeilen tragen zwar kein
  # `submitted_at`, aber der Riegel ist bewusst doppelt (auf Produktion sind
  # Statusaenderungen an der Datenbank vorgekommen).
  scope :awaiting_lv_review, lambda {
    joins(:referee_course_import)
      .where.not(submitted_at: nil)
      .where.not(referee_course_imports: { status: 'cancelled' })
  }

  # Symmetrische Match-Regel, die sowohl der Import-Service als auch der
  # LV-Review-Controller verwenden muessen, damit der Match-Score zwischen
  # initialem Import und nachtraeglicher Bearbeitung konsistent bleibt: leeres
  # Feld auf einer Seite zaehlt als Match.
  # csv_attrs: Hash mit Keys :lizenznummer, :vorname, :nachname, :geburtsdatum,
  # :verein, :email. Den Vereinsabgleich macht der uebergebene Block; er
  # bekommt den Namen aus der Datei und liefert ein
  # RefereeClubLookup::Result (Alias, exakt name/long_name, dann normalisiert;
  # mehrdeutig gilt als kein Treffer). Die Semantik MUSS auf beiden Seiten
  # dieselbe sein, sonst faellt der Score beim Bearbeiten anders aus als beim
  # Import.
  def self.count_csv_to_referee_matches(csv_attrs, referee, club_lookup:)
    return 0 unless referee

    matches = 0
    matches += 1 if field_match?(csv_attrs[:lizenznummer], referee.lizenznummer, :lizenznummer)
    matches += 1 if field_match?(csv_attrs[:vorname], referee.vorname, :vorname)
    matches += 1 if field_match?(csv_attrs[:nachname], referee.nachname, :nachname)
    matches += 1 if field_match?(csv_attrs[:geburtsdatum], referee.geburtsdatum, :geburtsdatum)
    matches += 1 if field_match?(csv_attrs[:email], referee.email, :email)

    matches += 1 if club_match?(csv_attrs[:verein], referee, club_lookup)

    matches
  end

  # Wie bei den anderen fuenf Merkmalen zaehlt „keine Aussage" als Treffer:
  # leere Zelle, kein Verein beim Schiedsrichter -- und ein Platzhalter statt
  # eines Vereinsnamens. Die Kursdateien fuehren im Vereinsfeld
  # gelegentlich „-", „ohne Verein" oder „Karriere beendet"
  # (RefereeClubLookup::PLACEHOLDERS); das ist kein abweichender Verein,
  # sondern gar keiner. Ohne diese Zeile kostete ein „-" einen Match-Punkt und
  # schickte die Zeile zur Freigabe an den Landesverband, waehrend dieselbe
  # Zeile mit leerer Zelle 6/6 erreichte.
  def self.club_match?(csv_verein, referee, club_lookup)
    return true if csv_verein.blank? || referee.club_id.blank?

    result = club_lookup.call(csv_verein)
    return true if result.match_type == :placeholder

    result.club_id == referee.club_id
  end

  def self.field_match?(csv_val, ref_val, field)
    return true if csv_val.blank? || ref_val.blank?

    case field
    when :vorname, :nachname, :email
      csv_val.to_s.strip.casecmp(ref_val.to_s.strip).zero?
    else
      csv_val == ref_val
    end
  end

  # Gegenstueck zum Scope `awaiting_lv_review` fuer eine einzelne Zeile: Freigeben
  # und Zurueckweisen duerfen nur eingereichte Zeilen.
  def awaiting_lv_review?
    submitted_at.present? && referee_course_import.status != 'cancelled'
  end

  # Eingereicht: Der Submit hat die Zeile angefasst -- sie ist angewendet oder
  # wartet auf die Freigabe des Landesverbands. Die Gegenrichtung („noch in der
  # Hand des Importeurs") ist die Bedingung fuers Bearbeiten, Zurueckstellen
  # und Verwerfen; sie verlangt zusaetzlich den Zeilenstatus, siehe
  # RefereeCourseResultsController#importer_can_edit?.
  def submitted?
    submitted_at.present?
  end

  # Final master values default to importer-chosen values until LV review
  # changes them. Convenience reader uses the final values.
  def master_for(field)
    self["master_#{field}_final"]
  end

  def importer_master_for(field)
    self["master_#{field}_by_importer"]
  end

  def diffs_between_importer_and_final
    MASTER_FIELDS.each_with_object({}) do |field, hash|
      a = importer_master_for(field)
      b = master_for(field)
      hash[field] = { from: a, to: b } if a != b
    end
  end

  def short_hash
    {
      id:,
      referee_course_import_id:,
      referee_id:,
      state_association_id:,
      status:,
      deferred:,
      submitted_at: submitted_at&.iso8601,
      match_type:,
      match_field_count:,
      lizenzstufe:,
      gueltigkeit:,
      kursstichtag:,
      master: master_hash,
      csv: csv_hash,
      master_by_importer: master_by_importer_hash,
      new_referee_created:,
      reviewed_by_user_id:,
      reviewed_at: reviewed_at&.iso8601,
      applied_at: applied_at&.iso8601,
      course_data: course_data || {},
      import_warnings: import_warnings || [],
      lv_changes: diffs_between_importer_and_final,
      rejection_reason:
    }
  end

  def csv_hash
    {
      lizenznummer: csv_lizenznummer,
      vorname:      csv_vorname,
      nachname:     csv_nachname,
      geburtsdatum: csv_geburtsdatum,
      verein:       csv_verein,
      email:        csv_email
    }
  end

  def master_hash
    {
      lizenznummer: master_lizenznummer_final,
      vorname:      master_vorname_final,
      nachname:     master_nachname_final,
      geburtsdatum: master_geburtsdatum_final,
      club_id:      master_club_id_final,
      email:        master_email_final
    }
  end

  def master_by_importer_hash
    {
      lizenznummer: master_lizenznummer_by_importer,
      vorname:      master_vorname_by_importer,
      nachname:     master_nachname_by_importer,
      geburtsdatum: master_geburtsdatum_by_importer,
      club_id:      master_club_id_by_importer,
      email:        master_email_by_importer
    }
  end
end
