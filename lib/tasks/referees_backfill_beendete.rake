require 'csv'

# Nachimport der Schiedsrichter mit beendeter Karriere und Nachziehen fehlender
# Vereinszuordnungen.
#
# Der Re-Sync von 2025 (referees2025:sync) hat bewusst nur die 4.426 Aktiven
# übernommen. Damit fehlt das Register der alten Lizenznummern: Wer nach Jahren
# zurückkommt und seine alte Nummer nennt, ist nicht prüfbar, und die Nummer ist
# technisch nicht belegt. Dieser Task holt die rund 4.250 Beendeten nach.
#
# Ablauf in drei Schritten, jeweils erst der Probelauf:
#
#   1. Stammdaten der Beendeten anlegen
#      rails referees2025:backfill_beendete CSV=tmp/referees_stammdaten.csv
#      rails referees2025:backfill_beendete CSV=… DRY_RUN=false
#
#   2. Fehlende Vereinszuordnungen nachziehen (wirkt auch auf die Aktiven)
#      rails referees2025:fill_club_ids CSV=tmp/referees_stammdaten.csv
#      rails referees2025:fill_club_ids CSV=… DRY_RUN=false
#
#   3. Kurs- und Lizenzhistorie der Beendeten (eigener Batch, sonst kollidiert
#      sie mit den bereits importierten Jahrgängen der Aktiven)
#      rails referees2025:import_history HISTORY_CSV=tmp/referees_historie_beendet.csv
#
# DRY_RUN ist Standard und rollt die Transaktion am Ende zurück. Läuft der Task
# gegen eine andere Datenbank als Produktion, zeigt die Alias-Liste ins Leere —
# dann ALIASES=<pfad zu einer passenden yml> mitgeben.
#
# referees2025:sync darf NICHT erneut laufen: Er setzt die Aktiven auf den
# Excel-Stand von Juli 2025 zurück und überschreibt alles, was seither über
# Kursimporte und Pflege dazugekommen ist.
module RefereesBackfill
  module_function

  def dry_run?
    ENV['DRY_RUN'] != 'false'
  end

  # Die ausgelieferte Alias-Datei trägt Produktions-Vereins-IDs. Damit die Tasks
  # auch gegen eine andere Datenbank (Staging, Test) laufen können, ohne dass
  # der Alias-Check zu Recht abbricht, ist die Quelle überschreibbar:
  #   ALIASES=/pfad/zu/aliases.yml
  def lookup
    path = ENV.fetch('ALIASES', nil).presence
    aliases = path ? (YAML.safe_load_file(path) || {}) : RefereeClubLookup.load_aliases
    RefereeClubLookup.new(aliases: aliases)
  end

  REQUIRED_HEADERS = %w[lizenznummer nachname vorname geburtsdatum verein aktiv lizenz lizenz_jahr].freeze

  def load_rows
    path = ENV.fetch('CSV', nil)
    abort 'Bitte CSV=<pfad> angeben (erzeugt von scripts/export_schiedsrichterliste_csvs.py)' if path.blank?
    abort "Datei nicht gefunden: #{path}" unless File.exist?(path)

    # 'bom|UTF-8' statt 'UTF-8': Sonst klebt ein BOM am ersten Spaltennamen und
    # jeder Zugriff darauf liefert nil. Der Kopf wird geprüft, weil eine fehlende
    # Spalte `aktiv` den Filter stumm ins Leere laufen ließe — dann gälte keine
    # Zeile als beendet und der Task liefe über den gesamten Bestand.
    table = CSV.read(path, col_sep: ';', headers: true, encoding: 'bom|UTF-8')
    missing = REQUIRED_HEADERS - table.headers.map(&:to_s)
    abort "CSV-Spalten fehlen: #{missing.join(', ')}" if missing.any?

    table
  end

  def parse_date(value)
    return nil if value.blank?

    Date.strptime(value.to_s.strip, '%d.%m.%Y')
  rescue ArgumentError
    nil
  end

  # Gleiche Regeljahr-Logik wie im Re-Sync: Eine Lizenz aus Kursjahr X läuft im
  # Folgejahr ab, in Regeljahren (alle vier Jahre) am 31.07., sonst am 30.09.
  def gueltigkeit_for_kursjahr(jahr)
    return nil if jahr.blank?

    folgejahr = jahr.to_i + 1
    (folgejahr % 4) == 2 ? Date.new(folgejahr, 7, 31) : Date.new(folgejahr, 9, 30)
  end

  def same_person?(referee, row)
    normalize_name(referee.nachname) == normalize_name(row['nachname']) &&
      normalize_name(referee.vorname) == normalize_name(row['vorname'])
  end

  def normalize_name(value)
    value.to_s.downcase.gsub('ß', 'ss').gsub(/[^a-zäöü]/, '')
  end

  def summarize(counter, label)
    puts label
    counter.sort_by { |_, count| -count }.each do |key, count|
      puts format('    %<key>-24s %<count>5d', key: key, count: count)
    end
    puts format('    %<key>-24s %<count>5d', key: 'SUMME', count: counter.values.sum)
  end

  def list_unmatched(unmatched)
    return if unmatched.empty?

    puts
    puts 'Vereinsnamen ohne Zuordnung (für die Alias-Liste):'
    unmatched.each do |match_type, names|
      puts "    #{match_type} (#{names.size} verschiedene):"
      names.sort.each { |name| puts "        #{name}" }
    end
  end

  # Harter Abbruch statt Warnung: Ein Alias-Ziel, das es nicht mehr gibt (etwa
  # nach clubs:merge), lässt die betroffenen Schiedsrichter ohne Verein — und
  # eine Warnung in Zeile drei einer langen Ausgabe liest niemand.
  def check_aliases!(lookup)
    puts "Alias-Einträge geladen: #{lookup.alias_count}"
    return if lookup.missing_alias_targets.empty?

    abort "ABBRUCH: Alias-Ziele ohne Club-Datensatz: #{lookup.missing_alias_targets.join(', ')} — " \
          'config/referee_club_aliases.yml gegen die Vereinsliste prüfen.'
  end

  def finish(dry_run)
    if dry_run
      puts
      puts 'DRY RUN – nichts gespeichert. Mit DRY_RUN=false ausführen.'
      raise ActiveRecord::Rollback
    end

    puts
    puts 'Gespeichert.'
  end
end

namespace :referees2025 do
  desc 'Nachimport der Schiedsrichter mit beendeter Karriere (CSV=referees_stammdaten.csv, DRY_RUN=false zum Schreiben)'
  task backfill_beendete: :environment do
    rows = RefereesBackfill.load_rows.reject { |row| row['aktiv'] == '1' }
    lookup = RefereesBackfill.lookup
    dry_run = RefereesBackfill.dry_run?

    puts "=== Nachimport Karriere beendet [#{dry_run ? 'DRY RUN' : 'LIVE'}] ==="
    puts "Zeilen mit aktiv=0 in der CSV: #{rows.size}"
    RefereesBackfill.check_aliases!(lookup)
    puts

    created = 0
    filled = []
    unchanged = 0
    conflicts = []
    errors = []
    club_matches = Hash.new(0)
    unmatched_clubs = Hash.new { |hash, key| hash[key] = Set.new }

    ActiveRecord::Base.transaction do
      rows.each do |row|
        nr = row['lizenznummer'].to_i
        next errors << "Zeile ohne Lizenznummer: #{row['nachname']}, #{row['vorname']}" if nr.zero?

        club = lookup.call(row['verein'])
        club_matches[club.match_type] += 1
        # Die Namen mitschreiben, nicht nur zählen: Der Probelauf existiert, um
        # vor dem scharfen Lauf die Alias-Liste zu ergänzen, und dafür braucht
        # es die Namen, die nicht getroffen haben.
        unmatched_clubs[club.match_type] << row['verein'] if row['verein'].present? && !club.matched?

        attrs = {
          vorname: row['vorname'],
          nachname: row['nachname'],
          geburtsdatum: RefereesBackfill.parse_date(row['geburtsdatum']),
          club_id: club.club_id,
          lizenzstufe: row['lizenz'].presence,
          gueltigkeit: RefereesBackfill.gueltigkeit_for_kursjahr(row['lizenz_jahr'])
        }

        # Bewusst ohne `canonical`: Die Lizenznummer ist eindeutig indiziert, ein
        # gemergter Datensatz behält sie. Würde er hier übersehen, liefe das
        # Anlegen in eine Unique-Verletzung. Er wird gefunden, aber nicht
        # befüllt — die Nummer gehört fachlich an den Master.
        referee = Referee.find_by(lizenznummer: nr)

        if referee&.merged_into_id.present?
          conflicts << "Lizenznr. #{nr}: Datensatz ist in ##{referee.merged_into_id} gemergt, " \
                       'Nummer gehört an den Master'
          next
        end

        if referee.nil?
          begin
            Referee.create!(attrs.merge(lizenznummer: nr, guest: false))
            created += 1
          rescue ActiveRecord::RecordInvalid => e
            errors << "Lizenznr. #{nr}: #{e.message}"
          end
          next
        end

        # Nummer existiert bereits. Namensgleichheit entscheidet, ob wir
        # denselben Menschen vor uns haben. Bei Abweichung wird NICHT
        # überschrieben: Auf dieser Nummer kann eine Tester-Anlage oder ein
        # Datensatz aus dem Altdaten-Spielimport sitzen.
        unless RefereesBackfill.same_person?(referee, row)
          conflicts << "Lizenznr. #{nr}: DB „#{referee.nachname}, #{referee.vorname}" \
                       "\" ≠ Excel „#{row['nachname']}, #{row['vorname']}\""
          next
        end

        leere = attrs.select { |field, value| value.present? && referee[field].blank? }
        if leere.empty?
          unchanged += 1
          next
        end

        referee.update!(leere)
        filled << "Lizenznr. #{nr}: #{leere.keys.join(', ')}"
      end

      # Bei Fehlern wird zurückgerollt — dann sind die folgenden Zahlen das,
      # was passiert WÄRE. Ohne diese Überschrift liest man oben „Neu angelegt:
      # 4250" und überliest den Abbruch weiter unten.
      if errors.any?
        puts '=== VERWORFEN (Rollback) — die folgenden Zahlen wären das Ergebnis gewesen ==='
      end

      puts "Neu angelegt:                       #{created}"
      puts "Vorhanden, leere Felder ergänzt:    #{filled.size}"
      puts "Vorhanden, unverändert:             #{unchanged}"
      puts "Namenskonflikt, nichts geändert:    #{conflicts.size}"
      verarbeitet = created + filled.size + unchanged + conflicts.size + errors.size
      if verarbeitet != rows.size
        raise "Zeilen nicht abgeglichen: #{rows.size - verarbeitet} von #{rows.size} unberücksichtigt"
      end

      puts
      RefereesBackfill.summarize(club_matches, 'Vereinszuordnung:')
      RefereesBackfill.list_unmatched(unmatched_clubs)

      if filled.any?
        puts
        puts 'Ergänzte Felder (erste 20):'
        filled.first(20).each { |line| puts "    #{line}" }
      end

      if conflicts.any?
        puts
        puts 'Namenskonflikte (manuell prüfen, nichts geändert):'
        conflicts.each { |line| puts "    #{line}" }
      end

      if errors.any?
        puts
        puts "ABGEBROCHEN — #{errors.size} Fehler, keine Änderung übernommen:"
        errors.each { |line| puts "    #{line}" }
        raise ActiveRecord::Rollback
      end

      RefereesBackfill.finish(dry_run)
    end

    exit 1 if errors.any?
  end

  desc 'Fehlende club_id aus der Excel nachziehen (CSV=referees_stammdaten.csv, DRY_RUN=false zum Schreiben)'
  task fill_club_ids: :environment do
    rows = RefereesBackfill.load_rows
    lookup = RefereesBackfill.lookup
    dry_run = RefereesBackfill.dry_run?

    puts "=== Fehlende Vereinszuordnungen [#{dry_run ? 'DRY RUN' : 'LIVE'}] ==="
    RefereesBackfill.check_aliases!(lookup)

    by_nr = Referee.where(guest: false, merged_into_id: nil).where.not(lizenznummer: nil).index_by(&:lizenznummer)
    puts "Schiedsrichter in der DB: #{by_nr.size}, davon ohne Verein: #{by_nr.values.count { |r| r.club_id.blank? }}"
    puts

    filled = Hash.new(0)
    stays_empty = Hash.new(0)
    already_set = 0
    not_in_db = 0
    name_conflicts = []
    disagreements = []

    ActiveRecord::Base.transaction do
      rows.each do |row|
        referee = by_nr[row['lizenznummer'].to_i]
        if referee.nil?
          not_in_db += 1
          next
        end

        # Dieselbe Namensprüfung wie im Nachimport: Auf einer Lizenznummer kann
        # ein Datensatz aus dem Altdaten-Spielimport sitzen. Ohne die Prüfung
        # bekäme diese fremde Person still den Verein aus der Excel-Zeile.
        unless RefereesBackfill.same_person?(referee, row)
          name_conflicts << "Lizenznr. #{referee.lizenznummer}: DB „#{referee.nachname}, " \
                            "#{referee.vorname}\" ≠ Excel „#{row['nachname']}, #{row['vorname']}\""
          next
        end

        club = lookup.call(row['verein'])

        if referee.club_id.present?
          already_set += 1
          # Bestehende Zuordnungen werden nie überschrieben: Welcher Wert
          # stimmt, steht nicht in den Daten. Widersprüche nur melden.
          if club.matched? && club.club_id != referee.club_id
            disagreements << "Lizenznr. #{referee.lizenznummer}: DB ##{referee.club_id} " \
                             "≠ Excel ##{club.club_id} („#{row['verein']}\")"
          end
          next
        end

        if club.matched?
          referee.update!(club_id: club.club_id)
          filled[club.match_type] += 1
        else
          stays_empty[club.match_type] += 1
        end
      end

      RefereesBackfill.summarize(filled, 'Verein nachgetragen:') if filled.any?
      puts
      RefereesBackfill.summarize(stays_empty, 'Bleibt ohne Verein:') if stays_empty.any?
      puts
      puts "Bereits gesetzt (unangetastet):     #{already_set}"
      puts "davon Widerspruch zur Excel:        #{disagreements.size}"
      disagreements.each { |line| puts "    #{line}" }
      puts "Keine Entsprechung in der DB:       #{not_in_db}"
      puts "Namenskonflikt, nichts geändert:    #{name_conflicts.size}"
      name_conflicts.each { |line| puts "    #{line}" }

      # Jede CSV-Zeile muss in genau einem Topf landen. Ohne diese Probe sähe
      # ein Lauf, in dem 90 Prozent der Datei nichts traf, wie ein sauberer aus.
      verarbeitet = filled.values.sum + stays_empty.values.sum + already_set +
                    not_in_db + name_conflicts.size
      if verarbeitet != rows.size
        raise "Zeilen nicht abgeglichen: #{rows.size - verarbeitet} von #{rows.size} unberücksichtigt"
      end

      RefereesBackfill.finish(dry_run)
    end
  end
end
