# Antrag eines Schiedsrichters, einen Verein auf seine Ausschlussliste zu setzen
# (kind "add") oder ihn wieder zu streichen (kind "remove"). Entschieden wird er
# von der Ansetzung (Rolle Ansetzer) des zuständigen Spielbetriebs.
class RefereeClubExclusionRequest < ApplicationRecord
  KINDS = %w[add remove].freeze
  STATUSES = %w[pending approved rejected withdrawn].freeze

  belongs_to :referee
  belongs_to :club

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :reason, presence: true, length: { maximum: 120 }
  validates :decision_note, length: { maximum: 200 }
  validate :no_open_request, on: :create
  validate :kind_matches_current_list, on: :create

  scope :pending, -> { where(status: 'pending') }

  def pending?
    status == 'pending'
  end

  # Genehmigt den Antrag und zieht die Ausschlussliste nach. Gibt false zurück,
  # wenn der Antrag zwischenzeitlich (etwa im Parallel-Tab) schon entschieden
  # wurde – die Sperre verhindert, dass zwei Klicks doppelt wirken.
  def approve!(user_id, note = nil)
    self.class.transaction do
      lock!
      return false unless pending?

      kind == 'add' ? create_exclusion!(user_id) : remove_exclusion!
      update!(status: 'approved', decision_note: note.presence,
              decided_by: user_id, decided_at: Time.current)
    end
    true
  end

  def reject!(user_id, note)
    self.class.transaction do
      lock!
      return false unless pending?

      update!(status: 'rejected', decision_note: note, decided_by: user_id, decided_at: Time.current)
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

  def as_json(*)
    {
      id:,
      referee_id:,
      club_id:,
      club_name: club&.name,
      kind:,
      reason:,
      status:,
      decision_note:,
      decided_at: decided_at&.iso8601,
      created_at: created_at&.iso8601
    }
  end

  private

  def create_exclusion!(user_id)
    # Der Verein kann zwischen Antrag und Entscheidung zum eigenen Verein
    # geworden sein (Vereinswechsel). Dann steht er ohnehin abgeleitet auf der
    # Liste und der Antrag gilt als erfüllt, statt an der Validierung zu
    # scheitern.
    return if referee&.club_id == club_id

    exclusion = RefereeClubExclusion.find_or_initialize_by(referee_id:, club_id:)
    exclusion.reason = reason
    exclusion.created_by = user_id
    exclusion.request_id = id
    exclusion.save!
  end

  def remove_exclusion!
    RefereeClubExclusion.where(referee_id:, club_id:).destroy_all
  end

  def no_open_request
    return if referee_id.blank? || club_id.blank?
    return unless self.class.pending.where(referee_id:, club_id:).exists?

    errors.add(:base, 'Für diesen Verein liegt bereits ein offener Antrag vor.')
  end

  # "add" nur für einen Verein, der noch nicht auf der Liste steht, "remove" nur
  # für einen gelisteten. Der eigene Verein steht immer auf der Liste (abgeleitet)
  # und lässt sich weder erneut aufnehmen noch streichen.
  def kind_matches_current_list
    return if referee_id.blank? || club_id.blank? || kind.blank?

    listed = referee&.club_id == club_id ||
             RefereeClubExclusion.where(referee_id:, club_id:).exists?

    if kind == 'add' && listed
      errors.add(:base, 'Dieser Verein steht bereits auf deiner Liste.')
    elsif kind == 'remove' && !listed
      errors.add(:base, 'Dieser Verein steht nicht auf deiner Liste.')
    elsif kind == 'remove' && referee&.club_id == club_id
      errors.add(:base, 'Der eigene Verein lässt sich nicht von der Liste streichen.')
    end
  end
end
