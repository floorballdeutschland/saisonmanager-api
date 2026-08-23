# Antrag eines Schiedsrichters auf Korrektur der eigenen Stammdaten. Diese vier
# Felder sind im Profil bewusst gesperrt (der Name steht auf dem digitalen
# Ausweis, der Verein bestimmt Zuständigkeit und Ansetzbarkeit), deshalb geht
# eine Änderung über einen Antrag. Entschieden wird er von der RSK des
# Landesverbands, in dem der Verein des Schiris liegt.
class RefereeChangeRequest < ApplicationRecord
  CORRECTION_TYPES = %w[vorname nachname geburtsdatum verein].freeze
  STATUSES = %w[pending approved rejected withdrawn].freeze

  LABELS = {
    'vorname' => 'Vorname',
    'nachname' => 'Nachname',
    'geburtsdatum' => 'Geburtsdatum',
    'verein' => 'Verein'
  }.freeze

  belongs_to :referee
  # Nur bei correction_type 'verein': der Verein, in den der Schiri wechseln
  # will.
  belongs_to :new_club, class_name: 'Club', optional: true

  validates :correction_type, inclusion: { in: CORRECTION_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :new_value, presence: true, unless: :club_change?
  validates :new_value, length: { maximum: 120 }
  validates :new_club, presence: true, if: :club_change?
  validates :reason, length: { maximum: 200 }
  validates :decision_note, length: { maximum: 200 }
  validate :new_value_must_be_a_date, if: -> { correction_type == 'geburtsdatum' && new_value.present? }
  validate :new_club_must_be_active, on: :create, if: -> { club_change? && new_club.present? }
  validate :no_open_request, on: :create
  validate :must_change_something, on: :create

  scope :pending, -> { where(status: 'pending') }

  def pending?
    status == 'pending'
  end

  def club_change?
    correction_type == 'verein'
  end

  # Genehmigt den Antrag und schreibt den neuen Wert ans Schiri-Profil. Gibt
  # false zurück, wenn der Antrag zwischenzeitlich (etwa im Parallel-Tab) schon
  # entschieden wurde, damit zwei Klicks nicht doppelt wirken.
  def approve!(user_id, note = nil)
    self.class.transaction do
      lock!
      return false unless pending?

      apply!
      update!(status: 'approved', decision_note: note.presence,
              reviewed_by_user_id: user_id, decided_at: Time.current)
    end
    true
  end

  def reject!(user_id, note)
    self.class.transaction do
      lock!
      return false unless pending?

      update!(status: 'rejected', decision_note: note,
              reviewed_by_user_id: user_id, decided_at: Time.current)
    end
    true
  end

  def withdraw!
    self.class.transaction do
      lock!
      return false unless pending?

      update!(status: 'withdrawn')
    end
    true
  end

  def label
    LABELS[correction_type]
  end

  # Der Wert, der aktuell am Profil steht. Bewusst zum Anzeigezeitpunkt gelesen
  # und nicht beim Anlegen kopiert: Wurde das Feld zwischenzeitlich von Hand
  # korrigiert, soll die Entscheidung den echten Stand zeigen und nicht den von
  # damals.
  def current_value
    case correction_type
    when 'vorname' then referee.vorname
    when 'nachname' then referee.nachname
    when 'geburtsdatum' then referee.geburtsdatum&.iso8601
    when 'verein' then referee.club&.name
    end
  end

  # Der beantragte Wert als Text, für Mail und Anzeige.
  def requested_value
    club_change? ? new_club&.name : new_value
  end

  def as_json(*)
    {
      id:,
      referee_id:,
      correction_type:,
      label:,
      new_value:,
      new_club_id:,
      new_club_name: new_club&.name,
      current_value:,
      requested_value:,
      reason:,
      status:,
      decision_note:,
      decided_at: decided_at&.iso8601,
      created_at: created_at&.iso8601
    }
  end

  private

  def apply!
    case correction_type
    when 'vorname' then referee.update!(vorname: new_value)
    when 'nachname' then referee.update!(nachname: new_value)
    # geburtsdatum ist eine date-Spalte: Ein unlesbarer String würde beim
    # Zuweisen still zu nil gecastet und das Geburtsdatum löschen, deshalb
    # explizit parsen und bei Unlesbarkeit laut scheitern.
    when 'geburtsdatum' then referee.update!(geburtsdatum: parsed_birthdate!)
    # Der Vereinswechsel verschiebt den Schiri in die Zuständigkeit eines
    # anderen Landesverbands. Das ist der Sinn des Antrags und deshalb hier
    # erlaubt, obwohl die Schiedsrichterverwaltung das Feld einer LV-RSK nicht
    # zum freien Bearbeiten gibt (restricted_referee_params).
    when 'verein' then referee.update!(club_id: new_club_id)
    end
  end

  def no_open_request
    return if referee_id.blank? || correction_type.blank?
    return unless self.class.pending.where(referee_id:, correction_type:).exists?

    errors.add(:base, "Für #{label || 'dieses Feld'} liegt bereits ein offener Antrag vor.")
  end

  # Ein Antrag, der nichts ändert, wäre für die RSK nicht zu entscheiden: Er
  # sähe nach einem Versehen aus und ein „genehmigt" bliebe folgenlos.
  def must_change_something
    return if referee.blank? || correction_type.blank?

    same = if club_change?
             new_club_id.present? && new_club_id == referee.club_id
           else
             new_value.present? && new_value == current_value
           end
    return unless same

    errors.add(:base, "#{label} steht bereits so im Profil.")
  end

  def parsed_birthdate!
    Date.iso8601(new_value.to_s)
  rescue ArgumentError, TypeError
    errors.add(:new_value, 'muss ein gültiges Datum sein (JJJJ-MM-TT)')
    raise ActiveRecord::RecordInvalid, self
  end

  # Bewusst Date.iso8601 und nicht Date.parse: Date.parse liest auch Bruchstücke
  # („03" wird zum 3. des laufenden Monats). So ein Wert käme durch die
  # Zukunftsprüfung, sähe im Antrag nach einem Versehen aus und überschriebe bei
  # der Genehmigung das echte Geburtsdatum. Nebenbei hält die strenge Form den
  # Vergleich in must_change_something ehrlich, der auf der ISO-Schreibweise von
  # current_value beruht.
  def new_value_must_be_a_date
    date = Date.iso8601(new_value.to_s)
    errors.add(:new_value, 'darf nicht in der Zukunft liegen') if date > Date.current
  rescue ArgumentError, TypeError
    errors.add(:new_value, 'muss ein gültiges Datum sein (JJJJ-MM-TT)')
  end

  # Die Vereinsauswahl im Profil zeigt nur aktive Vereine; ein Antrag auf einen
  # stillgelegten Verein (Ablage, Fusion) käme also nur an der Maske vorbei und
  # würde den Schiri bei der Genehmigung in einen Verein setzen, den es nicht
  # mehr gibt.
  def new_club_must_be_active
    return if new_club.deactivated_at.nil?

    errors.add(:new_club, 'ist nicht aktiv')
  end
end
