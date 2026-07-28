# Ein Verein, für dessen Spiele ein Schiedsrichter nicht angesetzt werden soll.
# Die Liste ist ausdrücklich eine Warnung und kein Filter: Die Ansetzung sieht
# den Hinweis im UI, kann die Person aber weiterhin auswählen.
#
# Der eigene Verein steht bewusst NICHT in dieser Tabelle, sondern wird aus
# referees.club_id abgeleitet (siehe .club_ids_by_referee). Damit wandert er bei
# einem Vereinswechsel automatisch mit und hinterlässt keine Altzeilen.
class RefereeClubExclusion < ApplicationRecord
  belongs_to :referee
  belongs_to :club

  validates :reason, length: { maximum: 120 }
  validates :club_id, uniqueness: { scope: :referee_id }
  validate :not_own_club, on: :create

  # Vereins-IDs je Schiri (eigener Verein + gepflegte Ausschlüsse), ohne N+1.
  # Erwartet geladene Referee-Objekte, weil club_id daraus stammt.
  def self.club_ids_by_referee(referees)
    result = referees.each_with_object({}) { |r, acc| acc[r.id] = [r.club_id].compact }
    return result if result.empty?

    where(referee_id: result.keys).pluck(:referee_id, :club_id).each do |referee_id, club_id|
      (result[referee_id] ||= []) << club_id
    end
    result.transform_values(&:uniq)
  end

  private

  # Der eigene Verein ist bereits abgeleitet auf der Liste; eine zusätzliche
  # Zeile würde ihn doppelt anzeigen. Der Antragsweg verbietet das schon
  # (RefereeClubExclusionRequest#kind_matches_current_list), die direkte Pflege
  # durch die Ansetzung braucht dieselbe Sperre.
  def not_own_club
    return if club_id.blank? || referee&.club_id != club_id

    errors.add(:club_id, 'ist der eigene Verein und steht bereits auf der Liste')
  end
end
