# frozen_string_literal: true

# Wer im Beobachtungsbogen einzeln bewertet wird, und wer im Gespann ohne
# Bewertung bleibt.
#
# Bewertet werden nur Schiedsrichter mit eigenem, regulärem Profil. Ein
# Gastschiedsrichter (referees.guest) wird nie einzeln bewertet: Er steht im
# Spielbericht als Freitext, hat im Regelfall kein Konto und könnte den Bogen
# nicht lesen. Das gilt auch dann, wenn er über die Ansetzung als Datensatz
# auflösbar wäre (Game#feedback_referees fällt ohne auflösbaren Bericht auf die
# Ansetzung zurück). Pfeift ein Gast mit einem regulären Partner, wird nur der
# Partner bewertet; die Gespann-Bewertung bleibt davon unberührt.
#
# unrated_names sind die Namen, die der Bogen als Hinweis zeigt: Gäste aus der
# Ansetzung und Einträge des Spielberichts ohne reguläres Profil.
class RefereeObservationCrew
  attr_reader :entries, :unrated_names

  # crew: [referees, names] aus Game#feedback_referees bzw. .feedback_referees_for
  def initialize(game, crew = nil)
    referees, names = crew || game.feedback_referees
    # Position = Slot im Gespann, vor dem Herausfiltern bestimmt: Pfeift der
    # Gast auf Slot 1, bleibt der Partner Schiedsrichter 2.
    all = referees.each_with_index.map do |referee, index|
      { referee: referee, name: names[index], position: index + 1 }
    end
    @entries = all.reject { |entry| entry[:referee].guest }
    @unrated_names = collect_unrated(game, all.select { |entry| entry[:referee].guest })
  end

  def referees
    @entries.map { |entry| entry[:referee] }
  end

  def empty?
    @entries.empty?
  end

  private

  def collect_unrated(game, guest_entries)
    names = guest_entries.map { |entry| entry[:name] }
    game.referees.each do |report_entry|
      next if rated?(report_entry)

      names << "#{report_entry[:first_name]} #{report_entry[:last_name]}".strip
    end
    names.compact_blank.uniq { |name| normalize(name) }
  end

  # Ein Eintrag des Spielberichts gehört zu einer bewerteten Person, wenn
  # Lizenznummer oder Name passen. Der Name allein genügt nicht immer (ein
  # umbenannter Schiri), die Lizenznummer allein auch nicht (Altdaten ohne
  # Nummer, Spiele mit Live-Erfassung).
  def rated?(report_entry)
    license = report_entry[:license_id].to_i
    name = normalize("#{report_entry[:first_name]} #{report_entry[:last_name]}")
    @entries.any? do |entry|
      (license.positive? && entry[:referee].lizenznummer.to_i == license) ||
        normalize(entry[:name]) == name
    end
  end

  def normalize(name)
    name.to_s.squish.downcase
  end
end
