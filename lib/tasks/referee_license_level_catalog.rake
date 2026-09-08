# lib/tasks/referee_license_level_catalog.rake
#
#   rake referees:license_level_catalog        (DRY_RUN=1 zeigt nur an)
#
# Einmalige Einrichtung des Lizenzstufen-Katalogs (api#638). KEIN Cronjob.
#
# Drei Dinge in einem Lauf, weil sie nur zusammen wirken:
#
#   1. `position` an allen Stufen setzen. Die Spalte traegt die Rangfolge
#      (niedrigere Position = hoehere Stufe), war aber seit jeher ueberall nil.
#      Solange sie leer ist, sortiert die Verwaltungsliste die Spalte
#      alphabetisch statt nach Rang, `RefereeLicenseLevel.ordered` faellt auf
#      den Namen zurueck, und die Downgrade-Warnung des Kursimports
#      (RefereeCourseResultApplier#log_downgrade_if_any) ist toter Code: sie
#      bricht bei `return unless current_pos && new_pos` immer ab.
#
#   2. `N4` anlegen, inaktiv. Die Stufe steht an 44 Schiedsrichtern und in 445
#      Kursergebnissen, hatte aber nie einen Katalogeintrag. Inaktiv heisst:
#      nicht mehr vergebbar, Bestand bleibt -- wie N3.
#
#   3. Kursnamen und Schreibfehler im Stufenfeld korrigieren. `G3` ist keine
#      Lizenzstufe, sondern der Name des KURSES, der zur L3 fuehrt; `G2` steht
#      entsprechend fuer L2, `l1` ist eine Kleinschreibung von L1. Diese Werte
#      stehen in `referee_course_results.lizenzstufe` und wandern von dort ueber
#      RefereeCourseResultApplier unveraendert auf den Schiedsrichter -- so sind
#      die fuenf G3-Schiedsrichter ueberhaupt entstanden. Ohne diesen Schritt
#      entstehen nach jedem Kursimport neue Datensaetze mit einer Stufe, die der
#      Katalog nicht kennt, und die Positionen aus Schritt 1 laufen wieder ins
#      Leere.
#
# Idempotent: Ein zweiter Lauf findet nichts mehr zu tun und meldet das.
module RefereeLicenseLevelCatalog
  # Rangfolge laut Verband: die N-Familie vollstaendig ueber der L-Familie,
  # LJ (Jugend) als unterste Stufe.
  POSITIONS = {
    'N1' => 1, 'N2' => 2, 'N3' => 3, 'N4' => 4,
    'L1' => 5, 'L2' => 6, 'L3' => 7, 'LJ' => 8
  }.freeze

  # Fehlt im Katalog. validity_years ist Pflicht (>= 1) und fuer eine nicht mehr
  # vergebbare Stufe fachlich bedeutungslos -- 1 wie der Modell-Default.
  MISSING_LEVELS = [
    { name: 'N4', position: 4, active: false, validity_years: 1 }
  ].freeze

  # Kursname bzw. Schreibweise => tatsaechliche Lizenzstufe.
  CORRECTIONS = { 'G3' => 'L3', 'G2' => 'L2', 'l1' => 'L1' }.freeze

  module_function

  def run(dry_run:)
    puts "== Lizenzstufen-Katalog ==#{' (DRY RUN -- es wird nichts geschrieben)' if dry_run}"

    ActiveRecord::Base.transaction do
      angelegt = create_missing_levels(dry_run)
      gesetzt  = assign_positions(dry_run)
      korr     = correct_level_values(dry_run)

      puts "\nErgebnis: #{angelegt} Stufe(n) angelegt, #{gesetzt} Position(en) gesetzt, " \
           "#{korr[:results]} Kursergebnis(se) und #{korr[:referees]} Schiedsrichter korrigiert."
      report_unknown_levels
      raise ActiveRecord::Rollback if dry_run
    end
  end

  def create_missing_levels(dry_run)
    fehlend = MISSING_LEVELS.reject { |attrs| RefereeLicenseLevel.exists?(name: attrs[:name]) }
    if fehlend.empty?
      puts "\n[1/3] Fehlende Stufen: keine."
      return 0
    end

    puts "\n[1/3] Fehlende Stufen:"
    fehlend.each do |attrs|
      traeger = Referee.where(lizenzstufe: attrs[:name]).count
      puts "  anlegen: #{attrs[:name]} position=#{attrs[:position]} aktiv=#{attrs[:active]} " \
           "gueltigkeit=#{attrs[:validity_years]} Jahr(e), #{traeger} Schiedsrichter tragen sie"
      RefereeLicenseLevel.create!(attrs) unless dry_run
    end
    fehlend.size
  end

  def assign_positions(dry_run)
    puts "\n[2/3] Positionen:"
    geaendert = 0
    RefereeLicenseLevel.order(:name).each do |level|
      ziel = POSITIONS[level.name]
      if ziel.nil?
        puts "  #{level.name} -- keine Rangfolge hinterlegt, bleibt #{level.position.inspect}"
        next
      end
      next if level.position == ziel

      puts "  #{level.name} #{level.position.inspect} -> #{ziel}"
      level.update!(position: ziel) unless dry_run
      geaendert += 1
    end
    puts '  nichts zu tun.' if geaendert.zero?
    geaendert
  end

  # Erst die Kursergebnisse, dann die Schiedsrichter: Die Ergebnisse sind die
  # Quelle, aus der die falschen Werte nachwachsen.
  def correct_level_values(dry_run)
    puts "\n[3/3] Kursnamen und Schreibweisen im Stufenfeld:"
    results = 0
    referees = 0

    CORRECTIONS.each do |falsch, richtig|
      r_count = RefereeCourseResult.where(lizenzstufe: falsch).count
      s_count = Referee.where(lizenzstufe: falsch).count
      next if r_count.zero? && s_count.zero?

      puts "  #{falsch} -> #{richtig} : #{r_count} Kursergebnis(se), " \
           "#{s_count} Schiedsrichter#{validity_warning(falsch, richtig)}"
      unless dry_run
        RefereeCourseResult.where(lizenzstufe: falsch).update_all(lizenzstufe: richtig)
        Referee.where(lizenzstufe: falsch).update_all(lizenzstufe: richtig)
      end
      results  += r_count
      referees += s_count
    end
    puts '  nichts zu tun.' if results.zero? && referees.zero?
    { results: results, referees: referees }
  end

  # Die Korrektur ist folgenlos, solange beide Stufen dieselbe Gueltigkeitsdauer
  # haben (eine unbekannte Stufe rechnet mit DEFAULT_VALIDITY_YEARS = 1).
  # Unterscheiden sie sich, rechnet ein kuenftiges Kursergebnis auf diese Zeile
  # ein anderes Ablaufdatum aus -- das gehoert benannt, nicht stillschweigend.
  def validity_warning(falsch, richtig)
    alt = validity_years_for(falsch)
    neu = validity_years_for(richtig)
    return '' if alt == neu

    "  ACHTUNG: Gueltigkeitsdauer #{alt} -> #{neu} Jahr(e)"
  end

  def validity_years_for(name)
    RefereeLicenseLevel.find_by(name: name)&.validity_years || RefereeLicenseLevel::DEFAULT_VALIDITY_YEARS
  end

  # Was danach noch an Stufen im Bestand steht, das der Katalog nicht kennt.
  # Kein Abbruch: Der Lauf soll zeigen, was er nicht entscheiden kann.
  def report_unknown_levels
    bekannt = RefereeLicenseLevel.pluck(:name) + MISSING_LEVELS.map { |attrs| attrs[:name] }
    offen = unknown_levels(Referee, bekannt)
    offen_results = unknown_levels(RefereeCourseResult, bekannt)
    return if offen.empty? && offen_results.empty?

    puts "\nUnbekannte Stufen bleiben stehen (weder Katalog noch Korrekturliste):"
    puts "  Schiedsrichter:  #{offen.inspect}" if offen.any?
    puts "  Kursergebnisse:  #{offen_results.inspect}" if offen_results.any?
  end

  def unknown_levels(model, bekannt)
    model.where.not(lizenzstufe: [nil, '']).where.not(lizenzstufe: bekannt).group(:lizenzstufe).count
  end
end

namespace :referees do
  desc 'Lizenzstufen-Katalog einrichten: Positionen, fehlende Stufen, Kursnamen im Stufenfeld (DRY_RUN=1)'
  task license_level_catalog: :environment do
    RefereeLicenseLevelCatalog.run(dry_run: ENV['DRY_RUN'].present?)
  end
end
