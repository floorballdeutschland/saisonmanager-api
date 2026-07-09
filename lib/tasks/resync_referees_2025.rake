require 'csv'
require 'set'

# Re-Sync der Schiedsrichter-Stammdaten aus der FD-Excel "Schiedsrichterliste
# 2025" (Echtdaten) + Import der historischen Kurs-/Testergebnisse.
#
# Die CSVs erzeugt scripts/export_schiedsrichterliste_csvs.py aus der Excel.
#
#   rails referees_2025:report          CSV=tmp/referees_stammdaten.csv
#   rails referees_2025:sync            CSV=tmp/referees_stammdaten.csv
#   rails referees_2025:import_history  HISTORY_CSV=tmp/referees_historie.csv [UPLOADED_BY=admin]
#
# Regeln (siehe Konverter): Karriere gilt nach 5 Jahren ohne Lizenz als beendet
# (aktiv=0) — diese Schiedsrichter werden weder aktualisiert noch angelegt,
# bestehende DB-Einträge bleiben aber unangetastet (historische Spiele
# referenzieren sie über die Lizenznummer). Schiedsrichter in der DB, deren
# Lizenznummer gar nicht in der Excel vorkommt (= Tester-Anlagen), löscht der
# Sync — außer es hängen Verknüpfungen dran (Login, Ansetzungen, Feedbacks,
# Kursergebnisse, Spiel-Referenzen, Merges); die werden nur gelistet.
module Referees2025Resync
  HISTORY_IMPORT_FILENAME_PREFIX = 'Schiedsrichterliste 2025.xlsx – Jahr'.freeze

  module_function

  def load_csv(env_key)
    path = ENV.fetch(env_key, nil)
    abort "Bitte #{env_key}=<pfad> angeben (erzeugt von scripts/export_schiedsrichterliste_csvs.py)" if path.blank?
    abort "Datei nicht gefunden: #{path}" unless File.exist?(path)

    CSV.read(path, col_sep: ';', headers: true, encoding: 'UTF-8')
  end

  def parse_date(value)
    return nil if value.blank?

    Date.strptime(value.to_s.strip, '%d.%m.%Y')
  rescue ArgumentError
    nil
  end

  # Lizenz aus Kursjahr X gilt bis ins Folgejahr: In Regeljahren (alle 4 Jahre:
  # 2022, 2026, 2030, …) nur bis 31.07., in allen anderen Jahren bis 30.09.
  def gueltigkeit_for_kursjahr(jahr)
    return nil if jahr.blank?

    folgejahr = jahr.to_i + 1
    if (folgejahr % 4) == 2
      Date.new(folgejahr, 7, 31)
    else
      Date.new(folgejahr, 9, 30)
    end
  end

  def club_lookup
    @club_lookup ||= Hash.new do |cache, name|
      cache[name] = Club.where('LOWER(name) = LOWER(?)', name.strip).first
    end
  end

  # Ziel-Attribute eines aktiven Excel-Schiedsrichters. Nur Felder, die die
  # Excel als Echtdaten führt — E-Mail, Telefon, Adresse etc. bleiben unberührt.
  # Verein nur bei exaktem Namens-Match, Geburtsdatum nur wenn in der Excel
  # vorhanden (nicht leeren).
  def desired_attrs(row)
    attrs = { vorname: row['vorname'], nachname: row['nachname'] }

    geburtsdatum = parse_date(row['geburtsdatum'])
    attrs[:geburtsdatum] = geburtsdatum if geburtsdatum

    club = row['verein'].present? ? club_lookup[row['verein']] : nil
    attrs[:club_id] = club.id if club

    if row['lizenz'].present?
      attrs[:lizenzstufe] = row['lizenz']
      attrs[:gueltigkeit] = gueltigkeit_for_kursjahr(row['lizenz_jahr'])
    end

    attrs
  end

  def db_referees
    Referee.where(merged_into_id: nil, guest: false).to_a
  end

  # Gründe, die einer Löschung entgegenstehen. Verfügbarkeiten, Qualifikationen,
  # Tags und Spieltag-Bestätigungen hängen als dependent: :destroy dran und
  # zählen bewusst nicht als Blocker.
  def deletion_blockers(referee)
    blockers = []
    blockers << 'Login-Account' if User.exists?(referee_id: referee.id)
    blockers << 'Kursergebnisse' if RefereeCourseResult.exists?(referee_id: referee.id)
    if RefereeAssignment.where(referee1_id: referee.id).or(RefereeAssignment.where(referee2_id: referee.id)).exists?
      blockers << 'Ansetzungen'
    end
    if RefereeFeedback.where(referee1_id: referee.id).or(RefereeFeedback.where(referee2_id: referee.id)).exists?
      blockers << 'Schiri-Feedbacks'
    end
    blockers << 'Merge-Ziel' if Referee.exists?(merged_into_id: referee.id)
    if Game.where('? = ANY(nominated_referee_ids) OR ? = ANY(officiating_referee_ids)', referee.id, referee.id).exists?
      blockers << 'Spiel-Nominierungen'
    end
    blockers << 'Spiel-Einsätze' if referee.lizenznummer.present? && referee.games.exists?
    blockers
  end

  def label(referee)
    "##{referee.id} Lizenznr. #{referee.lizenznummer || '-'} #{referee.nachname}, #{referee.vorname}"
  end
end

namespace :referees_2025 do
  desc 'Read-only-Abgleich DB vs. Excel-CSV (CSV=referees_stammdaten.csv)'
  task report: :environment do
    rows = Referees2025Resync.load_csv('CSV')
    db_refs = Referees2025Resync.db_referees
    by_nr = db_refs.select { |r| r.lizenznummer.present? }.index_by(&:lizenznummer)
    excel_numbers = rows.map { |r| r['lizenznummer'].to_i }.to_set

    diffs = []
    to_create = []
    unmatched_clubs = Hash.new(0)
    ended_in_db = 0

    rows.each do |row|
      nr = row['lizenznummer'].to_i
      referee = by_nr[nr]

      if row['aktiv'] != '1'
        ended_in_db += 1 if referee
        next
      end

      if row['verein'].present? && Referees2025Resync.club_lookup[row['verein']].nil?
        unmatched_clubs[row['verein']] += 1
      end

      if referee.nil?
        to_create << "Lizenznr. #{nr} #{row['nachname']}, #{row['vorname']} (#{row['verein']})"
        next
      end

      referee.assign_attributes(Referees2025Resync.desired_attrs(row))
      changes = referee.changes.map { |field, (from, to)| "#{field}: #{from.inspect} → #{to.inspect}" }
      diffs << "#{Referees2025Resync.label(referee)} | #{changes.join(' | ')}" if changes.any?
      referee.restore_attributes
    end

    deletable = []
    blocked = []
    db_refs.each do |referee|
      next if referee.lizenznummer.present? && excel_numbers.include?(referee.lizenznummer)

      blockers = Referees2025Resync.deletion_blockers(referee)
      if blockers.empty?
        deletable << Referees2025Resync.label(referee)
      else
        blocked << "#{Referees2025Resync.label(referee)} | blockiert durch: #{blockers.join(', ')}"
      end
    end

    aktive = rows.count { |r| r['aktiv'] == '1' }
    puts "Excel: #{rows.size} Schiedsrichter (#{aktive} aktiv, #{rows.size - aktive} Karriere beendet)"
    puts "DB: #{db_refs.size} Schiedsrichter (unmerged, ohne Gäste)"
    puts "Karriere beendet, in DB vorhanden (bleiben unangetastet): #{ended_in_db}"
    puts
    puts "=== Feld-Abweichungen bei aktiven Schiedsrichtern: #{diffs.size} ==="
    diffs.each { |line| puts line }
    puts
    puts "=== Neu anzulegen (aktiv, nicht in DB): #{to_create.size} ==="
    to_create.each { |line| puts line }
    puts
    puts "=== Tester-Anlagen, löschbar: #{deletable.size} ==="
    deletable.each { |line| puts line }
    puts
    puts "=== Tester-Anlagen, NICHT löschbar: #{blocked.size} ==="
    blocked.each { |line| puts line }
    puts
    puts "=== Vereine ohne exakten Namens-Match (club_id bleibt unverändert): #{unmatched_clubs.size} ==="
    unmatched_clubs.sort_by { |_, count| -count }.each { |name, count| puts "#{name} (#{count} Schiris)" }
  end

  desc 'Upsert aktiver Schiedsrichter aus der Excel-CSV + Löschen von Tester-Anlagen (CSV=referees_stammdaten.csv)'
  task sync: :environment do
    rows = Referees2025Resync.load_csv('CSV')
    db_refs = Referees2025Resync.db_referees
    by_nr = db_refs.select { |r| r.lizenznummer.present? }.index_by(&:lizenznummer)
    excel_numbers = rows.map { |r| r['lizenznummer'].to_i }.to_set

    created = 0
    updated = 0
    unchanged = 0
    skipped_ended = 0
    errors = []

    ActiveRecord::Base.transaction do
      rows.each do |row|
        if row['aktiv'] != '1'
          skipped_ended += 1
          next
        end

        nr = row['lizenznummer'].to_i
        referee = by_nr[nr] || Referee.new(lizenznummer: nr, guest: false)
        is_new = referee.new_record?
        referee.assign_attributes(Referees2025Resync.desired_attrs(row))

        if !is_new && !referee.changed?
          unchanged += 1
          next
        end

        begin
          referee.save!
          is_new ? created += 1 : updated += 1
        rescue ActiveRecord::RecordInvalid => e
          errors << "Lizenznr. #{nr}: #{e.message}"
        end
      end

      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      puts "ABGEBROCHEN — #{errors.size} Fehler, keine Änderung übernommen:"
      errors.each { |line| puts "  #{line}" }
      exit 1
    end

    deleted = []
    blocked = []
    db_refs.each do |referee|
      next if referee.lizenznummer.present? && excel_numbers.include?(referee.lizenznummer)

      blockers = Referees2025Resync.deletion_blockers(referee)
      if blockers.any?
        blocked << "#{Referees2025Resync.label(referee)} | blockiert durch: #{blockers.join(', ')}"
        next
      end

      begin
        referee.destroy!
        deleted << Referees2025Resync.label(referee)
      rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotDestroyed => e
        blocked << "#{Referees2025Resync.label(referee)} | Löschen fehlgeschlagen: #{e.class}"
      end
    end

    puts "Sync abgeschlossen: #{created} angelegt, #{updated} aktualisiert, #{unchanged} unverändert, " \
         "#{skipped_ended} übersprungen (Karriere beendet)."
    puts
    puts "=== Tester-Anlagen gelöscht: #{deleted.size} ==="
    deleted.each { |line| puts line }
    puts
    puts "=== Tester-Anlagen NICHT gelöscht (bitte manuell prüfen): #{blocked.size} ==="
    blocked.each { |line| puts line }
  end

  desc 'Historische Kurs-/Testergebnisse 2011-2025 als Course-Results importieren (HISTORY_CSV=referees_historie.csv)'
  task import_history: :environment do
    rows = Referees2025Resync.load_csv('HISTORY_CSV')
    uploader = User.find_by(user_name: ENV.fetch('UPLOADED_BY', 'admin'))
    abort "Upload-User nicht gefunden (UPLOADED_BY=#{ENV.fetch('UPLOADED_BY', 'admin')})" if uploader.nil?

    club_lookup = ->(name) { Referees2025Resync.club_lookup[name] }

    rows.group_by { |row| row['jahr'].to_i }.sort.each do |jahr, jahr_rows|
      filename = "#{Referees2025Resync::HISTORY_IMPORT_FILENAME_PREFIX} #{jahr}"
      if RefereeCourseImport.exists?(filename: filename)
        puts "#{jahr}: übersprungen (Import '#{filename}' existiert bereits)"
        next
      end

      created = 0
      skipped = []

      ActiveRecord::Base.transaction do
        import = RefereeCourseImport.create!(
          uploaded_by_user: uploader,
          filename: filename,
          status: 'submitted',
          total_rows: jahr_rows.size
        )

        jahr_rows.each do |row|
          nr = row['lizenznummer'].to_i
          referee = Referee.where(merged_into_id: nil).find_by(lizenznummer: nr)
          if referee.nil?
            skipped << nr
            next
          end

          geburtsdatum = Referees2025Resync.parse_date(row['geburtsdatum'])
          club = row['verein'].present? ? Referees2025Resync.club_lookup[row['verein']] : nil

          course_data = {
            'kurs_1' => {
              'stufe' => row['kurs1_stufe'].presence, 'datum' => row['kurs1_datum'].presence,
              'testversion' => row['kurs1_testversion'].presence, 'punkte' => row['kurs1_punkte'].presence
            },
            'kurs_2' => {
              'stufe' => row['kurs2_stufe'].presence, 'datum' => row['kurs2_datum'].presence,
              'testversion' => row['kurs2_testversion'].presence, 'punkte' => row['kurs2_punkte'].presence
            },
            'ausbilder' => nil
          }
          kursstichtag = [Referees2025Resync.parse_date(row['kurs1_datum']),
                          Referees2025Resync.parse_date(row['kurs2_datum'])].compact.max

          csv_attrs = { lizenznummer: nr, vorname: row['vorname'], nachname: row['nachname'],
                        geburtsdatum: geburtsdatum, verein: row['verein'].presence, email: nil }
          match_field_count = RefereeCourseResult.count_csv_to_referee_matches(
            csv_attrs, referee, club_lookup: club_lookup
          )

          RefereeCourseResult.create!(
            referee_course_import: import,
            referee: referee,
            state_association_id: club&.state_association_id || referee.club&.state_association_id,
            csv_lizenznummer: nr,
            csv_vorname: row['vorname'],
            csv_nachname: row['nachname'],
            csv_geburtsdatum: geburtsdatum,
            csv_verein: row['verein'].presence,
            csv_email: nil,
            lizenzstufe: row['lizenz'].presence,
            gueltigkeit: row['lizenz'].present? ? Referees2025Resync.gueltigkeit_for_kursjahr(jahr) : nil,
            kursstichtag: kursstichtag,
            course_data: course_data,
            import_warnings: [],
            match_type: 'exact_match',
            match_field_count: match_field_count,
            new_referee_created: false,
            status: 'applied',
            applied_at: Time.current,
            reviewed_by_user: uploader,
            reviewed_at: Time.current,
            master_lizenznummer_by_importer: nr, master_lizenznummer_final: nr,
            master_vorname_by_importer: row['vorname'], master_vorname_final: row['vorname'],
            master_nachname_by_importer: row['nachname'], master_nachname_final: row['nachname'],
            master_geburtsdatum_by_importer: geburtsdatum, master_geburtsdatum_final: geburtsdatum,
            master_club_id_by_importer: club&.id, master_club_id_final: club&.id,
            master_email_by_importer: nil, master_email_final: nil
          )
          created += 1
        end
      end

      line = "#{jahr}: #{created} Ergebnisse importiert"
      line += ", #{skipped.size} übersprungen (Lizenznr. nicht in DB: #{skipped.uniq.first(10).join(', ')}…)" if skipped.any?
      puts line
    end

    puts 'Hinweis: Die Ergebnisse sind reine Historie (status=applied, ohne Applier) — ' \
         'lizenzstufe/gueltigkeit am Schiedsrichter setzt referees_2025:sync.'
  end
end
