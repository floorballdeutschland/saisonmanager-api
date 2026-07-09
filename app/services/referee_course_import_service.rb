require 'csv'

class RefereeCourseImportService
  # CSV-Parsing ist positional, weil der Header doppelte Spaltennamen
  # ("Kurs 1"/"Kurs 2") enthält und CSV.parse damit keine eindeutige
  # Header-Map liefert. Die Constants unten sind die single source of truth
  # für die Spaltenreihenfolge.
  COLUMN_LIZENZNUMMER  = 0
  COLUMN_NACHNAME      = 1
  COLUMN_VORNAME       = 2
  COLUMN_GEBURTSDATUM  = 3
  COLUMN_VEREIN        = 4
  COLUMN_EMAIL         = 5
  COLUMN_KURS1_STUFE   = 6
  COLUMN_KURS1_DATUM   = 7
  COLUMN_KURS1_VERSION = 8
  COLUMN_KURS1_PUNKTE  = 9
  COLUMN_KURS2_STUFE   = 10
  COLUMN_KURS2_DATUM   = 11
  COLUMN_KURS2_VERSION = 12
  COLUMN_KURS2_PUNKTE  = 13
  COLUMN_AUSBILDER     = 14

  EXPECTED_COLUMN_COUNT = 15

  attr_reader :errors

  def initialize(csv_content:, filename:, uploaded_by_user:)
    @csv_content      = csv_content.to_s
    @filename         = filename
    @uploaded_by_user = uploaded_by_user
    @errors           = []
  end

  def call
    rows = parse_csv
    return nil if rows.nil?

    ActiveRecord::Base.transaction do
      import = RefereeCourseImport.create!(
        uploaded_by_user: @uploaded_by_user,
        filename: @filename,
        status: 'in_review',
        total_rows: rows.size
      )

      rows.each do |row|
        create_result(import, row)
      end

      import
    end
  end

  private

  def parse_csv
    content = @csv_content.dup
    content.force_encoding('UTF-8') if content.encoding != Encoding::UTF_8
    # BOM erst nach force_encoding strippen — eine /n-Regex (ASCII-8BIT) gegen
    # einen UTF-8-String mit Nicht-ASCII (Umlauten oder BOM) löst sonst
    # Encoding::CompatibilityError aus.
    content.sub!(/\A\u{FEFF}/, '')

    raw = CSV.parse(content, col_sep: ';', skip_blanks: true)
    header = raw.shift

    unless header_looks_valid?(header)
      @errors << 'CSV-Header nicht erkannt. Die erste Zeile muss die ' \
                 'Spaltenüberschriften enthalten und mit „Lizenznummer" beginnen.'
      return nil
    end

    rows = raw.map { |r| r.map { |v| v.to_s.strip } }
              .reject { |r| r.all? { |v| v.nil? || v.empty? } }

    if rows.empty?
      @errors << 'CSV enthält keine Datenzeilen.'
      return nil
    end

    rows
  rescue CSV::MalformedCSVError => e
    @errors << "CSV konnte nicht gelesen werden: #{e.message}"
    nil
  rescue EncodingError => e
    @errors << "Datei-Encoding wird nicht unterstützt (bitte als UTF-8 speichern): #{e.message}"
    nil
  end

  def header_looks_valid?(header)
    return false if header.blank?

    first = header.first.to_s.strip.downcase
    first.include?('lizenznummer')
  end

  def create_result(import, row)
    row += [nil] * (EXPECTED_COLUMN_COUNT - row.size) if row.size < EXPECTED_COLUMN_COUNT

    warnings = []

    csv_lizenznummer = parse_integer(row[COLUMN_LIZENZNUMMER], field: 'lizenznummer', warnings: warnings)
    csv_vorname      = presence(row[COLUMN_VORNAME])
    csv_nachname     = presence(row[COLUMN_NACHNAME])
    csv_geburtsdatum = parse_date(row[COLUMN_GEBURTSDATUM], field: 'geburtsdatum', warnings: warnings)
    csv_verein       = presence(row[COLUMN_VEREIN])
    csv_email        = presence(row[COLUMN_EMAIL])

    course_data = build_course_data(row, warnings: warnings)
    kursstichtag = compute_kursstichtag(course_data)
    gueltigkeit  = compute_gueltigkeit(kursstichtag)
    if kursstichtag.nil?
      warnings << { 'field' => 'kursstichtag', 'raw' => nil,
                    'reason' => 'kein gültiges Kurs-Datum erkannt — Gültigkeitsdatum kann nicht abgeleitet werden' }
    end

    csv_attrs = {
      lizenznummer: csv_lizenznummer,
      vorname:      csv_vorname,
      nachname:     csv_nachname,
      geburtsdatum: csv_geburtsdatum,
      verein:       csv_verein,
      email:        csv_email
    }

    referee, match_field_count = find_best_match(csv_attrs)

    match_type =
      if referee.nil?
        'new_entry'
      elsif match_field_count == 6
        'exact_match'
      else
        'partial_match'
      end

    matched_club = exact_club_match(csv_verein)

    importer_attrs = {
      master_lizenznummer_by_importer: csv_lizenznummer || referee&.lizenznummer,
      master_vorname_by_importer:      csv_vorname      || referee&.vorname,
      master_nachname_by_importer:     csv_nachname     || referee&.nachname,
      master_geburtsdatum_by_importer: csv_geburtsdatum || referee&.geburtsdatum,
      master_club_id_by_importer:      matched_club&.id || referee&.club_id,
      master_email_by_importer:        csv_email        || referee&.email
    }

    final_attrs = {
      master_lizenznummer_final: importer_attrs[:master_lizenznummer_by_importer],
      master_vorname_final:      importer_attrs[:master_vorname_by_importer],
      master_nachname_final:     importer_attrs[:master_nachname_by_importer],
      master_geburtsdatum_final: importer_attrs[:master_geburtsdatum_by_importer],
      master_club_id_final:      importer_attrs[:master_club_id_by_importer],
      master_email_final:        importer_attrs[:master_email_by_importer]
    }

    state_association_id =
      Club.find_by(id: importer_attrs[:master_club_id_by_importer])&.state_association_id

    RefereeCourseResult.create!(
      referee_course_import: import,
      referee:              referee,
      state_association_id: state_association_id,
      csv_lizenznummer:     csv_lizenznummer,
      csv_vorname:          csv_vorname,
      csv_nachname:         csv_nachname,
      csv_geburtsdatum:     csv_geburtsdatum,
      csv_verein:           csv_verein,
      csv_email:            csv_email,
      kursstichtag:         kursstichtag,
      gueltigkeit:          gueltigkeit,
      course_data:          course_data,
      import_warnings:      warnings,
      match_type:           match_type,
      match_field_count:    match_field_count,
      status:               'pending_review',
      **importer_attrs,
      **final_attrs
    )
  end

  # Findet den DB-Referee mit den meisten Übereinstimmungen.
  # Sonderregel: Eine CSV-Lizenznummer, die auf einen unmergeden Referee
  # trifft, ist immer der Match — unabhängig vom Score. Das verhindert, dass
  # ein Namensvetter mit mehr übereinstimmenden Feldern den Lizenznummer-
  # Träger „überholt" und damit eine kollidierende Neuanlage anstößt.
  def find_best_match(csv_attrs)
    if csv_attrs[:lizenznummer]
      ref = Referee.where(lizenznummer: csv_attrs[:lizenznummer], merged_into_id: nil).first
      return [ref, count_matches(csv_attrs, ref)] if ref
    end

    candidates = candidate_referees(csv_attrs)
    return [nil, 0] if candidates.empty?

    scored = candidates.map { |r| [r, count_matches(csv_attrs, r)] }
    scored.select! { |(_, c)| c >= 3 }
    return [nil, 0] if scored.empty?

    scored.max_by do |(r, c)|
      [c,
       r.lizenznummer && csv_attrs[:lizenznummer] == r.lizenznummer ? 1 : 0,
       r.geburtsdatum && csv_attrs[:geburtsdatum] == r.geburtsdatum ? 1 : 0,
       -r.id]
    end
  end

  def candidate_referees(csv_attrs)
    conditions = []
    args = {}

    if csv_attrs[:vorname] && csv_attrs[:nachname]
      conditions << '(LOWER(vorname) = LOWER(:vorname) AND LOWER(nachname) = LOWER(:nachname))'
      args[:vorname]  = csv_attrs[:vorname]
      args[:nachname] = csv_attrs[:nachname]
    end

    if csv_attrs[:nachname] && csv_attrs[:geburtsdatum]
      conditions << '(LOWER(nachname) = LOWER(:nachname2) AND geburtsdatum = :geburtsdatum)'
      args[:nachname2]    = csv_attrs[:nachname]
      args[:geburtsdatum] = csv_attrs[:geburtsdatum]
    end

    if csv_attrs[:email]
      conditions << 'LOWER(email) = LOWER(:email)'
      args[:email] = csv_attrs[:email]
    end

    return Referee.none if conditions.empty?

    Referee.where(merged_into_id: nil).where(conditions.join(' OR '), args).limit(20)
  end

  def count_matches(csv_attrs, referee)
    RefereeCourseResult.count_csv_to_referee_matches(
      csv_attrs, referee, club_lookup: ->(name) { exact_club_match(name) }
    )
  end

  def exact_club_match(name)
    return nil if name.blank?

    Club.where('LOWER(name) = LOWER(?)', name.strip).first
  end

  def build_course_data(row, warnings:)
    kurs1_datum = row[COLUMN_KURS1_DATUM].presence
    kurs2_datum = row[COLUMN_KURS2_DATUM].presence
    # Wir validieren das Datum (damit es im Warning auftaucht) und behalten
    # die Rohform in der JSONB-Spalte für UI-Anzeige.
    parse_date(kurs1_datum, field: 'kurs_1_datum', warnings: warnings) if kurs1_datum
    parse_date(kurs2_datum, field: 'kurs_2_datum', warnings: warnings) if kurs2_datum

    {
      'kurs_1' => {
        'stufe'       => presence(row[COLUMN_KURS1_STUFE]),
        'datum'       => kurs1_datum,
        'testversion' => presence(row[COLUMN_KURS1_VERSION]),
        'punkte'      => presence(row[COLUMN_KURS1_PUNKTE])
      },
      'kurs_2' => {
        'stufe'       => presence(row[COLUMN_KURS2_STUFE]),
        'datum'       => kurs2_datum,
        'testversion' => presence(row[COLUMN_KURS2_VERSION]),
        'punkte'      => presence(row[COLUMN_KURS2_PUNKTE])
      },
      'ausbilder' => presence(row[COLUMN_AUSBILDER])
    }
  end

  def compute_kursstichtag(course_data)
    # Reihenfolge der Keys ist irrelevant — `dates.max` bestimmt den Stichtag.
    dates = %w[kurs_1 kurs_2].filter_map do |key|
      parse_date(course_data.dig(key, 'datum'), field: key, warnings: nil)
    end
    dates.max
  end

  # Beim Import ist die Lizenzstufe noch unbekannt (setzt erst der LV-Review),
  # daher Ableitung mit der Default-Dauer. Sobald der Reviewer eine Stufe
  # setzt, leitet der Results-Controller mit deren validity_years neu ab —
  # Preview und Ergebnis nutzen so dieselbe Regel (inkl. Regeljahr-Stichtag).
  def compute_gueltigkeit(kursstichtag)
    return nil unless kursstichtag

    RefereeLicenseLevel.gueltigkeit_for(nil, kursstichtag)
  end

  def parse_integer(value, field:, warnings:)
    return nil if value.blank?

    Integer(value.to_s.strip, 10)
  rescue ArgumentError
    if warnings
      warnings << { 'field' => field, 'raw' => value.to_s,
                    'reason' => 'keine gültige Zahl — Feld wurde verworfen' }
    end
    nil
  end

  def parse_date(value, field:, warnings:)
    return nil if value.blank?
    return value if value.is_a?(Date)

    str = value.to_s.strip
    return nil if str.empty?

    parsed =
      begin
        Date.strptime(str, '%d.%m.%Y')
      rescue ArgumentError
        begin
          Date.strptime(str, '%Y-%m-%d')
        rescue ArgumentError
          nil
        end
      end

    if parsed.nil? && warnings
      warnings << { 'field' => field, 'raw' => str,
                    'reason' => 'kein gültiges Datum (erwartet TT.MM.JJJJ oder JJJJ-MM-TT) — Feld wurde verworfen' }
    end

    parsed
  end

  def presence(value)
    return nil if value.nil?

    str = value.to_s.strip
    str.empty? ? nil : str
  end
end
