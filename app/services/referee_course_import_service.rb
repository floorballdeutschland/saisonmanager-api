require 'csv'

class RefereeCourseImportService
  # Spalten werden primär über die Header-Namen aufgelöst. Die LV-Vorlagen
  # enthalten zusätzliche Arbeitsspalten (z. B. "Kommentar LV" vor "Ausbilder"),
  # die bei rein positionalem Lesen alles dahinter verschieben — und zwar still,
  # weil überzählige Spalten schlicht ignoriert werden.
  FIELD_ALIASES = {
    lizenznummer:  ['lizenznummer'].freeze,
    nachname:      %w[name nachname].freeze,
    vorname:       ['vorname'].freeze,
    geburtsdatum:  ['geburtsdatum'].freeze,
    verein:        ['verein'].freeze,
    email:         ['e-mail adresse', 'e-mail', 'email', 'e-mail-adresse'].freeze,
    kurs1_stufe:   ['kurs 1'].freeze,
    kurs1_datum:   ['kurs 1 datum'].freeze,
    kurs1_version: ['kurs 1 testversion'].freeze,
    kurs1_punkte:  ['kurs 1 punkte'].freeze,
    kurs2_stufe:   ['kurs 2'].freeze,
    kurs2_datum:   ['kurs 2 datum'].freeze,
    kurs2_version: ['kurs 2 testversion'].freeze,
    kurs2_punkte:  ['kurs 2 punkte'].freeze,
    ausbilder:     ['ausbilder', 'ausbilder/in', 'ausbilder(in)', 'ausbilderin',
                    'ausbilder*in', 'name ausbilder'].freeze
  }.freeze

  # Spaltenreihenfolge der Alt-Vorlage. Sie wiederholt denselben Namen für Stufe,
  # Datum und Punkte ("Kurs 1;Kurs 1;Kurs 1 Testversion;Kurs 1") und ist deshalb
  # nicht über den Header auflösbar — nur für sie gilt diese Zuordnung, siehe
  # legacy_layout?.
  DEFAULT_COLUMNS = {
    lizenznummer: 0, nachname: 1, vorname: 2, geburtsdatum: 3, verein: 4, email: 5,
    kurs1_stufe: 6, kurs1_datum: 7, kurs1_version: 8, kurs1_punkte: 9,
    kurs2_stufe: 10, kurs2_datum: 11, kurs2_version: 12, kurs2_punkte: 13,
    ausbilder: 14
  }.freeze

  # Breite der Alt-Vorlage. Bewusst als Literal und nicht als DEFAULT_COLUMNS.size:
  # käme später ein Feld hinzu (etwa ein Kurs 3), würde sich sonst die Schwelle
  # mitverschieben und der Fallback für echte Alt-Dateien anders greifen.
  LEGACY_COLUMN_COUNT = 15

  REQUIRED_FIELDS = %i[lizenznummer nachname vorname geburtsdatum].freeze

  # Plausibilitätsgrenzen für Datumsangaben. Date.strptime nimmt mit %Y auch
  # zweistellige Jahre an ("03.08.25" → Jahr 25), was aus einem als TT.MM.JJ
  # formatierten Excel-Blatt kommt und sonst unbemerkt eine Lizenz mit
  # Ablaufdatum in der Antike schreibt.
  MIN_PLAUSIBLE_YEAR = 1900

  FIELD_LABELS = {
    lizenznummer: 'Lizenznummer', nachname: 'Name', vorname: 'Vorname',
    geburtsdatum: 'Geburtsdatum', verein: 'Verein', email: 'E-Mail Adresse',
    ausbilder: 'Ausbilder'
  }.freeze

  attr_reader :errors

  def initialize(csv_content:, filename:, uploaded_by_user:)
    @csv_content      = csv_content.to_s
    @filename         = filename
    @uploaded_by_user = uploaded_by_user
    @errors           = []
  end

  def call
    rows, columns = parse_csv
    return nil if rows.nil?

    ActiveRecord::Base.transaction do
      import = RefereeCourseImport.create!(
        uploaded_by_user: @uploaded_by_user,
        filename: @filename,
        status: 'in_review',
        total_rows: rows.size
      )

      rows.each do |row|
        create_result(import, row, columns)
      end

      import
    end
  end

  private

  def parse_csv
    content = @csv_content.dup
    content.force_encoding('UTF-8') if content.encoding != Encoding::UTF_8
    # Encoding vor dem ersten mutierenden Regex prüfen: deutsches Excel schreibt
    # standardmäßig Windows-1252, und schon `sub!` wirft dagegen ArgumentError
    # ("invalid byte sequence in UTF-8"). ArgumentError ist kein EncodingError,
    # der rescue unten greift also nicht und der Upload endete im 500er statt in
    # dieser Meldung.
    unless content.valid_encoding?
      @errors << 'Datei-Encoding wird nicht unterstützt. Bitte die CSV als UTF-8 ' \
                 'speichern (in Excel: „CSV UTF-8 (durch Trennzeichen getrennt)").'
      return nil
    end

    # BOM erst nach force_encoding strippen — eine /n-Regex (ASCII-8BIT) gegen
    # einen UTF-8-String mit Nicht-ASCII (Umlauten oder BOM) löst sonst
    # Encoding::CompatibilityError aus.
    content.sub!(/\A\u{FEFF}/, '')
    # Excel-Exporte mischen die Zeilenenden: mehrzeilige Header-Zellen (in Quotes,
    # Inhalt "Kurs 1" + LF + "Datum") stehen mit LF, die Datenzeilen enden mit
    # CRLF. Rubys row_sep-Autoerkennung entscheidet sich dann für "\n" und
    # scheitert am verbleibenden CR ("Unquoted fields do not allow new line") —
    # die komplette Datei wird abgewiesen. Das Normalisieren behebt es; das
    # explizite row_sep unten ist nur Absicherung, danach gibt es kein CR mehr.
    content.gsub!(/\r\n?/, "\n")

    raw = CSV.parse(content, col_sep: ';', row_sep: "\n", skip_blanks: true)
    header = raw.shift

    columns = resolve_columns(header)
    return nil if columns.nil?

    # Leer ist eine Zeile, wenn in keiner *ausgewerteten* Spalte etwas steht. Ein
    # Eintrag allein in einer LV-Arbeitsspalte (etwa „Kommentar LV") erzeugte
    # sonst eine Ergebniszeile ohne jedes Feld, die den Submit später mit
    # „fehlt die Lizenzstufe" blockiert, ohne die Zeile zu benennen.
    rows = raw.map { |r| r.map { |v| v.to_s.strip } }
              .reject { |r| columns.each_value.all? { |i| r[i].nil? || r[i].empty? } }

    if rows.empty?
      @errors << 'CSV enthält keine Datenzeilen.'
      return nil
    end

    [rows, columns]
  rescue CSV::MalformedCSVError => e
    @errors << "CSV konnte nicht gelesen werden: #{e.message}"
    nil
  rescue EncodingError => e
    @errors << "Datei-Encoding wird nicht unterstützt (bitte als UTF-8 speichern): #{e.message}"
    nil
  end

  # Liefert die Feld-zu-Spaltenindex-Zuordnung oder nil (dann steht der Grund in
  # @errors).
  #
  # Der positionale Fallback ist die gefährliche Variante: er schreibt geratene
  # Indizes und hat vor diesem Umbau genau den Fehler erzeugt, den der Umbau
  # behebt. Er greift deshalb nur, wenn die Datei nachweislich die Alt-Vorlage
  # ist — siehe legacy_layout?. Reine Spaltenzahl-Gleichheit genügt nicht.
  def resolve_columns(header)
    if header.blank?
      @errors << 'CSV-Header nicht erkannt. Die erste Zeile muss die ' \
                 'Spaltenüberschriften enthalten.'
      return nil
    end

    mapped, ambiguous = map_header_columns(header)

    return DEFAULT_COLUMNS if legacy_layout?(header, mapped)

    fatal_ambiguous = ambiguous & REQUIRED_FIELDS
    if fatal_ambiguous.any?
      @errors << 'CSV-Spalten nicht eindeutig zuordenbar — auf ' \
                 "#{label_list(fatal_ambiguous)} passt jeweils mehr als eine Spalte. " \
                 'Bitte die Spaltenüberschriften der Vorlage verwenden.'
      return nil
    end

    missing = REQUIRED_FIELDS - mapped.keys
    if missing.any?
      @errors << "CSV fehlen Pflichtspalten: #{label_list(missing)}. " \
                 'Bitte die Spaltenüberschriften der Vorlage verwenden.'
      return nil
    end

    incomplete = incomplete_course_blocks(mapped)
    if incomplete.any?
      @errors << "Zu #{incomplete.join(' und ')} fehlt die Datumsspalte " \
                 "(erwartet „#{incomplete.first} Datum\"). Ohne Kursdatum lässt sich " \
                 'die Gültigkeit der Lizenz nicht berechnen.'
      return nil
    end

    log_unmapped(header, mapped, ambiguous)
    mapped
  end

  # Die Alt-Vorlage wiederholt denselben Namen für Stufe, Datum und Punkte
  # ("Kurs 1;Kurs 1;Kurs 1 Testversion;Kurs 1") und ist deshalb nicht über den
  # Header auflösbar. Erkennbar ist sie daran, dass sie genau so breit ist wie
  # DEFAULT_COLUMNS und *kein* per Namen erkanntes Feld der positionalen
  # Annahme widerspricht. Ohne diese zweite Bedingung würde jede fremde Datei
  # mit passender Spaltenzahl positional gelesen — bei umsortierten Spalten
  # landen dann etwa Vor- und Nachname vertauscht in der Datenbank, ohne
  # Fehlermeldung.
  def legacy_layout?(header, mapped)
    return false unless non_empty_header_count(header) == LEGACY_COLUMN_COUNT
    # Die Pflichtfelder müssen per Namen gefunden worden sein, sonst ist gar
    # nicht belegt, dass Zeile 1 überhaupt ein Header ist.
    return false unless REQUIRED_FIELDS.all? { |field| mapped.key?(field) }

    mapped.all? { |field, index| DEFAULT_COLUMNS[field] == index }
  end

  # Leere Zellen zählen nicht mit: Excel exportiert die benutzte Range und hängt
  # dabei gern eine angefasste Leerspalte an. header.size würde dadurch von der
  # Alt-Vorlage abweichen und sie fälschlich als fremde Datei behandeln.
  def non_empty_header_count(header)
    header.count { |raw_name| normalize_header_cell(raw_name).present? }
  end

  # Ein Kursblock, dessen Stufe/Testversion/Punkte erkannt wurden, dessen
  # Datumsspalte aber nicht: dann ist das Datum vorhanden und wird trotzdem nicht
  # gelesen. kursstichtag ist das Maximum beider Kursdaten, ein fehlender Block
  # verkürzt die Lizenzgültigkeit also stillschweigend — deshalb Abbruch.
  def incomplete_course_blocks(mapped)
    { 'Kurs 1' => %i[kurs1_stufe kurs1_version kurs1_punkte],
      'Kurs 2' => %i[kurs2_stufe kurs2_version kurs2_punkte] }.filter_map do |label, siblings|
      datum = label == 'Kurs 1' ? :kurs1_datum : :kurs2_datum
      label if siblings.any? { |f| mapped.key?(f) } && !mapped.key?(datum)
    end
  end

  def label_list(fields)
    fields.map { |field| FIELD_LABELS[field] || field.to_s }.join(', ')
  end

  # Gibt [{ feld => index }, [mehrdeutige felder]] zurück. Ein Feld, dessen
  # Überschrift gar nicht vorkommt, fehlt in der Map und wird beim Lesen zu nil.
  # In dieser Methode wird also nicht geraten; der positionale Fallback in
  # resolve_columns tut es bewusst und ist dort entsprechend abgesichert.
  # Mehrdeutig ist ein Feld, sobald mehrere Spalten auf seine Alias-Liste
  # passen — also auch bei zwei verschiedenen Schreibweisen („Name" und
  # „Nachname"), nicht nur bei wörtlich doppelten Überschriften.
  def map_header_columns(header)
    positions = {}
    header.each_with_index do |raw_name, index|
      name = normalize_header_cell(raw_name)
      next if name.empty?

      (positions[name] ||= []) << index
    end

    mapped    = {}
    ambiguous = []

    FIELD_ALIASES.each do |field, aliases|
      indexes = aliases.flat_map { |name| positions.fetch(name, []) }
      case indexes.size
      when 0 then next
      when 1 then mapped[field] = indexes.first
      else ambiguous << field
      end
    end

    [mapped, ambiguous]
  end

  # /\s+/ deckt U+00A0 nicht ab. Ein geschütztes Leerzeichen in der Überschrift
  # ist ein verbreitetes Excel- und Copy-Paste-Artefakt und würde die Spalte
  # unauffindbar machen.
  def normalize_header_cell(cell)
    cell.to_s.gsub(/[[:space:] ]+/, ' ').strip.downcase
  end

  # Beide Richtungen protokollieren: die übrigen Spalten (in der LV-Vorlage sind
  # das planmäßig die fünf Arbeitsspalten) und die Felder, die wir nicht gefunden
  # haben — letzteres ist die Angabe, mit der man etwas anfangen kann.
  def log_unmapped(header, mapped, ambiguous)
    used = mapped.values
    extra = header.each_with_index
                  .reject { |raw_name, index| used.include?(index) || normalize_header_cell(raw_name).empty? }
                  .map { |raw_name, _| normalize_header_cell(raw_name) }
    unresolved = (FIELD_ALIASES.keys - mapped.keys).map(&:to_s)
    return if extra.empty? && unresolved.empty?

    Rails.logger.info(
      "Kursergebnis-Import #{@filename}: nicht ausgewertete Spalten: " \
      "#{extra.presence&.join(', ') || '—'}; nicht gefundene Felder: " \
      "#{unresolved.presence&.join(', ') || '—'}" \
      "#{ambiguous.any? ? "; mehrdeutig (verworfen): #{ambiguous.join(', ')}" : ''}"
    )
  end

  def create_result(import, row, columns)
    warnings = []

    csv_lizenznummer = parse_integer(cell(row, columns, :lizenznummer), field: 'lizenznummer',
                                                                       warnings: warnings)
    csv_vorname      = presence(cell(row, columns, :vorname))
    csv_nachname     = presence(cell(row, columns, :nachname))
    csv_geburtsdatum = parse_date(cell(row, columns, :geburtsdatum), field: 'geburtsdatum',
                                                                    warnings: warnings)
    csv_verein       = presence(cell(row, columns, :verein))
    csv_email        = presence(cell(row, columns, :email))

    course_data = build_course_data(row, columns, warnings: warnings)
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

    warnings += reactivation_warning(referee)

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

  # Trifft ein Kursergebnis einen Schiedsrichter, dessen Lizenz vier Lizenzjahre
  # oder länger abgelaufen ist, ist das eine Reaktivierung: Die Karriere gilt als
  # beendet, fachlich ist der Grundkurs fällig und keine Fortbildung. In der
  # LV-Prüfansicht sähe man sonst einen unauffälligen Treffer und würde die alte
  # Lizenznummer stillschweigend wiederbeleben — genau der Fall, für den die
  # Beendeten überhaupt importiert wurden.
  def reactivation_warning(referee)
    return [] if referee.nil? || !referee.career_ended?

    [{ 'field' => 'lizenznummer', 'raw' => referee.lizenznummer.to_s,
       'reason' => 'Karriere beendet — Lizenz abgelaufen am ' \
                   "#{referee.gueltigkeit.strftime('%d.%m.%Y')}, Grundkurs erforderlich" }]
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

  def build_course_data(row, columns, warnings:)
    kurs1_datum = cell(row, columns, :kurs1_datum).presence
    kurs2_datum = cell(row, columns, :kurs2_datum).presence
    # Wir validieren das Datum (damit es im Warning auftaucht) und behalten
    # die Rohform in der JSONB-Spalte für UI-Anzeige.
    parse_date(kurs1_datum, field: 'kurs_1_datum', warnings: warnings) if kurs1_datum
    parse_date(kurs2_datum, field: 'kurs_2_datum', warnings: warnings) if kurs2_datum

    {
      'kurs_1' => {
        'stufe'       => presence(cell(row, columns, :kurs1_stufe)),
        'datum'       => kurs1_datum,
        'testversion' => presence(cell(row, columns, :kurs1_version)),
        'punkte'      => presence(cell(row, columns, :kurs1_punkte))
      },
      'kurs_2' => {
        'stufe'       => presence(cell(row, columns, :kurs2_stufe)),
        'datum'       => kurs2_datum,
        'testversion' => presence(cell(row, columns, :kurs2_version)),
        'punkte'      => presence(cell(row, columns, :kurs2_punkte))
      },
      'ausbilder' => presence(cell(row, columns, :ausbilder))
    }
  end

  # Fehlende Spalte oder zu kurze Zeile → nil (kein Fehler). Excel schneidet
  # leere Zellen am Zeilenende ab, kurze Zeilen sind also normal.
  def cell(row, columns, field)
    index = columns[field]
    return nil if index.nil?

    row[index]
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

    # %Y nimmt auch zwei Stellen an: "03.08.25" ergibt das Jahr 25. Das kommt aus
    # einem als TT.MM.JJ formatierten Excel-Blatt und ist gefährlicher als ein
    # unlesbares Datum, weil das Parsen ja gelingt — die Lizenz bekäme ein
    # Ablaufdatum in der Antike. Solche Werte gelten deshalb als ungültig.
    parsed = nil if parsed && !plausible_year?(parsed.year)

    if parsed.nil? && warnings
      warnings << { 'field' => field, 'raw' => str,
                    'reason' => 'kein gültiges Datum (erwartet TT.MM.JJJJ oder JJJJ-MM-TT, ' \
                                'Jahr vierstellig) — Feld wurde verworfen' }
    end

    parsed
  end

  def plausible_year?(year)
    year.between?(MIN_PLAUSIBLE_YEAR, Date.current.year + 10)
  end

  def presence(value)
    return nil if value.nil?

    str = value.to_s.strip
    str.empty? ? nil : str
  end
end
