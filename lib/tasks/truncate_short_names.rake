# Kürzt Bestands-Kürzel auf die neue Länge: Verein 4 Zeichen, Mannschaft 7.
#
# HINTERGRUND
#
# `clubs.short_name` und `teams.short_name` hatten nie eine Begrenzung. Das
# Kürzel ist aber ein Anzeigezeichen für die Anzeigetafel des Livestreams, und
# dort sprengt alles darüber die Bauchbinde (34px, uppercase, `nowrap`).
# `Team#ticker_short_name` deckelt die Anzeige seit derselben Änderung auf
# Team::SHORT_NAME_MAX, der gespeicherte Wert bleibt davon unberührt.
#
# WARUM DIE BESTANDSWERTE TROTZDEM WEG MÜSSEN
#
# Mit der Validierung lehnt jedes Speichern eines Vereins oder einer Mannschaft
# mit zu langem Kürzel ab – auch dann, wenn niemand das Kürzel anfassen wollte.
# Ein Verein, der nur seine Kontaktadresse eintragen will, käme nicht durch.
# Weil die Anzeige ohnehin kappt, geht durch das Kürzen keine Information
# verloren, die jemand zu sehen bekam.
#
# VEREINE MIT KOLLISION BLEIBEN STEHEN
#
# Auf Produktion fallen beim Kürzen auf vier Zeichen 21 Vereine in fünf Gruppen
# zusammen, allein sechsmal „U15 " für die U15-Trophy-Teams. Ein automatisch
# vergebenes, mehrfach vorkommendes Kürzel wäre auf der Anzeigetafel schlimmer
# als der Status quo, deshalb überspringt der Task diese Vereine und listet sie
# zur Pflege durch den jeweiligen Verband auf. Mannschaften sind davon nicht
# betroffen: Ihr Kürzel wird nirgends als Bezeichner gelesen.
#
# AUFRUF
#
#   rake kuerzel:report                    # nur lesend, zeigt beide Seiten
#   rake kuerzel:truncate                  # Vorschau (Dry-Run, Default)
#   DRY_RUN=false rake kuerzel:truncate    # ausführen
#
# Ein Lauf ist idempotent: Beim zweiten Mal findet er nichts mehr.

namespace :kuerzel do
  # Truthy-Default: Nur ein ausdrückliches DRY_RUN=false schreibt.
  def kuerzel_dry_run?
    ENV['DRY_RUN'] != 'false'
  end

  def kuerzel_gekuerzt(wert, max)
    wert.to_s.strip.slice(0, max).to_s.strip
  end

  # Vereine, deren gekürztes Kürzel mit einem anderen Verein zusammenfällt.
  # Verglichen wird gegen den kompletten Bestand nach dem Kürzen, nicht nur
  # gegen die zu kürzenden: Ein Verein mit bereits vier Zeichen kann das Ziel
  # besetzen.
  def kuerzel_club_kollisionen
    nachher = Club.where.not(short_name: [nil, '']).each_with_object(
      Hash.new { |h, k| h[k] = [] }
    ) do |club, acc|
      acc[kuerzel_gekuerzt(club.short_name, Club::SHORT_NAME_MAX).downcase] << club
    end

    nachher.select { |_, clubs| clubs.size > 1 }
  end

  desc 'Zeigt, welche Kuerzel zu lang sind und welche beim Kuerzen kollidieren'
  task report: :environment do
    clubs = Club.where('char_length(trim(short_name)) > ?', Club::SHORT_NAME_MAX)
    teams = Team.where('char_length(trim(teams.short_name)) > ?', Team::SHORT_NAME_MAX)

    puts "== Vereine über #{Club::SHORT_NAME_MAX} Zeichen: #{clubs.count} =="
    clubs.order(:name).each do |club|
      puts "  #{club.id}\t#{club.short_name.inspect} → " \
           "#{kuerzel_gekuerzt(club.short_name, Club::SHORT_NAME_MAX).inspect}\t#{club.name}"
    end

    kollisionen = kuerzel_club_kollisionen
    puts "\n== Kollisionen nach dem Kuerzen: #{kollisionen.size} Gruppen =="
    kollisionen.each do |ziel, betroffene|
      puts "  #{ziel.inspect} (#{betroffene.size}):"
      betroffene.each { |c| puts "    #{c.id}\t#{c.short_name.inspect}\t#{c.name}" }
    end

    puts "\n== Mannschaften über #{Team::SHORT_NAME_MAX} Zeichen: #{teams.count} =="
    puts "   davon aktuelle Saison: #{teams.merge(Team.current_season).count}"
  end

  desc 'Kuerzt Vereins- und Mannschaftskuerzel auf die neue Laenge (Dry-Run per Default)'
  task truncate: :environment do
    dry = kuerzel_dry_run?
    puts dry ? '=== VORSCHAU (DRY_RUN) ===' : '=== SCHARF (DRY_RUN=false) ==='

    kollidierende_ids = kuerzel_club_kollisionen.values.flatten.map(&:id).to_set
    club_gekuerzt = 0
    club_uebersprungen = []

    Club.where('char_length(trim(short_name)) > ?', Club::SHORT_NAME_MAX).find_each do |club|
      ziel = kuerzel_gekuerzt(club.short_name, Club::SHORT_NAME_MAX)

      if kollidierende_ids.include?(club.id)
        club_uebersprungen << [club, ziel]
        next
      end

      puts "  Verein #{club.id}: #{club.short_name.inspect} → #{ziel.inspect}"
      # update_column, weil die restlichen Stammdaten des Vereins nicht Teil
      # dieses Laufs sind: Ein Verein mit einer anderen offenen Ungueltigkeit
      # (etwa einer Altlast in den Pflichtfeldern) soll nicht mitscheitern.
      club.update_column(:short_name, ziel) unless dry
      club_gekuerzt += 1
    end

    team_gekuerzt = 0
    Team.where('char_length(trim(teams.short_name)) > ?', Team::SHORT_NAME_MAX).find_each do |team|
      ziel = kuerzel_gekuerzt(team.short_name, Team::SHORT_NAME_MAX)
      team.update_column(:short_name, ziel) unless dry
      team_gekuerzt += 1
    end

    puts "\n--- Ergebnis ---"
    puts "Vereine gekuerzt:        #{club_gekuerzt}"
    puts "Mannschaften gekuerzt:   #{team_gekuerzt}"
    puts "Vereine uebersprungen:   #{club_uebersprungen.size} (Kuerzel waere mehrfach vergeben)"
    club_uebersprungen.each do |club, ziel|
      puts "  #{club.id}\t#{club.short_name.inspect} → #{ziel.inspect} (belegt)\t#{club.name}"
    end
    puts "\nDiese Vereine brauchen ein eigenes Kuerzel vom jeweiligen Verband." if club_uebersprungen.any?
    puts "\nNichts geschrieben. Mit DRY_RUN=false ausfuehren." if dry
  end
end
