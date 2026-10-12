# frozen_string_literal: true

# Wer im Beobachtungsbogen einzeln bewertet wird, und wer im Gespann ohne
# Einzelbewertung bleibt.
#
# Einzeln bewertet werden nur Schiedsrichter mit regulärem Profil. Ein
# Gastschiedsrichter (referees.guest) nie: Er steht im Spielbericht meist als
# Freitext und hat im Regelfall kein Konto, der Bogen erreicht ihn also meist
# gar nicht. Das gilt auch dann, wenn er als Datensatz auflösbar wäre, etwa über
# die Ansetzung (Game#feedback_referees fällt ohne auflösbaren Bericht auf sie
# zurück). Pfeift ein Gast mit einem regulären Partner, wird nur der Partner
# bewertet; die Gespann-Bewertung bleibt davon unberührt.
#
# unrated_names sind die Namen für die Hinweise in Spielauswahl und Bogen: Gäste
# mit Datensatz und Einträge des Spielberichts, denen keine einzeln bewertete
# Person zugeordnet ist.
class RefereeObservationCrew
  attr_reader :entries, :unrated_names

  # crew: [referees, names] aus Game#feedback_referees, bzw. der Wert je Spiel
  # aus Game.feedback_referees_for(games)
  def initialize(game, crew = nil)
    @game = game
    referees, names = crew || game.feedback_referees
    all = referees.each_with_index.map do |referee, index|
      { referee: referee, name: names[index], position: index + 1 }
    end
    @entries = all.reject { |entry| entry[:referee].guest }
    assign_report_slots
    @unrated_names = collect_unrated(all.select { |entry| entry[:referee].guest })
  end

  def referees
    @entries.map { |entry| entry[:referee] }
  end

  def empty?
    @entries.empty?
  end

  private

  # Position = Slot im Spielbericht. Game#officiating_referees verdichtet nicht
  # auflösbare Slots (Freitext-Gäste) weg; ohne diesen Schritt rückte der Partner
  # eines Gastes auf Slot 1 auf. Ohne Bericht (Ansetzung) bleibt der Index aus
  # feedback_referees, vor dem Gast-Filter gezählt.
  def assign_report_slots
    slots = @entries.map { |entry| report_slot(entry[:referee]) || entry[:position] }
    return unless slots.uniq.size == slots.size

    @entries.each_with_index { |entry, index| entry[:position] = slots[index] }
  end

  def report_slot(referee)
    index = Array(@game.officiating_referee_ids).first(2).map(&:to_i).index(referee.id)
    if index.nil? && referee.lizenznummer.to_i.positive?
      index = @game.officiating_referee_licenses.index(referee.lizenznummer.to_i)
    end
    index && (index + 1)
  end

  def collect_unrated(guest_entries)
    names = guest_entries.map { |entry| entry[:name] }
    @game.referees.each do |report_entry|
      next if rated?(report_entry)

      names << "#{report_entry[:first_name]} #{report_entry[:last_name]}".strip
    end
    names.compact_blank.uniq { |name| normalize(name) }
  end

  # Ein Eintrag des Spielberichts gehört zu einer bewerteten Person, wenn
  # Lizenznummer oder Name passen. Der Name allein genügt nicht (ein umbenannter
  # Schiri), die Lizenznummer allein auch nicht (Einträge mit 0 oder einer
  # unbekannten Nummer, deren Person über die Ansetzung aufgelöst wurde).
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
