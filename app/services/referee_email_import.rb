require 'csv'

# Trägt E-Mail-Adressen aus einer CSV in bestehende Schiedsrichter-Profile ein.
#
# Geschrieben wird ausschließlich dort, wo noch keine Adresse steht: Die CSV ist
# eine Ergänzung der Bestandsdaten, nicht die Quelle der Wahrheit. Wer seine
# Adresse selbst im Profil gepflegt oder über den RSK korrigiert hat, darf sie
# nicht durch einen älteren Verbandsexport verlieren — und das fiele niemandem
# auf, weil die alte Adresse dabei spurlos verschwindet.
class RefereeEmailImport
  # Eine Datenzeile mit ihrer Nummer in der Datei. Die Nummer wird mitgeführt und
  # nicht aus dem Schleifenindex abgeleitet: Verworfene Leerzeilen verschieben den
  # Index, und der Report zeigte ab der ersten Leerzeile auf die falsche Zeile.
  Row = Struct.new(:number, :cells, keyword_init: true)

  # Obergrenze der verarbeiteten Datenzeilen. Der Import läuft in EINER
  # Transaktion; ohne Grenze könnte eine versehentlich hochgeladene Großdatei in
  # ein Timeout laufen, und der Rollback nähme dann auch den Report mit — der
  # Admin sähe nur einen Fehler und wüsste nicht, was geschrieben wurde.
  # Der gesamte Schiedsrichterbestand liegt deutlich darunter.
  MAX_DATA_ROWS = 20_000

  # Kopfzeilen-Namen, unter denen die beiden Spalten erkannt werden. Aufgelöst
  # wird über den Namen und nicht über die Position: Bei vertauschten Spalten
  # landen sonst alle Zeilen als „Lizenznummer ist keine Zahl" im Fehler-Topf,
  # und die Datei sieht kaputt aus, statt dass die Zuordnung benannt wird.
  LICENSE_ALIASES = ['lizenznummer', 'lizenz-nr.', 'lizenz-nr', 'lizenznr.', 'lizenznr',
                     'lizenz nr.', 'lizenz nr'].freeze
  EMAIL_ALIASES = ['e-mailadresse', 'e-mail-adresse', 'e-mail adresse', 'e-mailadresse sr',
                   'e-mail', 'email', 'emailadresse', 'mail'].freeze

  # Kandidaten für das Spaltentrennzeichen. Deutsches Excel schreibt Semikolon,
  # andere Werkzeuge Komma oder Tab; ausgezählt wird die Kopfzeile. Enthält sie
  # keines der drei (einspaltige Datei), bleibt es beim ersten Kandidaten, und
  # die Datei scheitert an den fehlenden Pflichtspalten.
  COL_SEPS = [';', ',', "\t"].freeze

  attr_reader :errors

  def initialize(csv_content:)
    @csv_content = csv_content.to_s
    @errors = []
  end

  # Liefert den Report-Hash oder nil — dann steht der Grund in #errors.
  def call
    parsed = parse_csv
    return nil if parsed.nil?

    rows, columns = parsed
    apply(rows, columns)
  end

  private

  def parse_csv
    content = normalized_content
    return nil if content.nil?

    # Bewusst OHNE skip_blanks: Eine verworfene Leerzeile darf die Zeilennummern
    # der folgenden Zeilen nicht verschieben. Leere Zeilen kommen als [] an und
    # fallen unten mit den inhaltlich leeren Zeilen zusammen heraus.
    raw = CSV.parse(content, col_sep: detect_col_sep(content), row_sep: "\n")
    header = raw.shift

    columns = resolve_columns(header)
    return nil if columns.nil?

    rows = data_rows(raw, columns)

    if rows.empty?
      @errors << 'CSV enthält keine Datenzeilen.'
      return nil
    end

    if rows.size > MAX_DATA_ROWS
      @errors << "Die Datei enthält #{rows.size} Datenzeilen, verarbeitet werden höchstens " \
                 "#{MAX_DATA_ROWS}. Bitte in mehreren Dateien hochladen."
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

  # Datenzeilen mit ihrer Nummer in der Datei. Leer ist eine Zeile, wenn in keiner
  # ausgewerteten Spalte etwas steht; solche Zeilen zählen nicht mit, verschieben
  # aber auch keine Nummer.
  def data_rows(raw, columns)
    raw.each_with_index.filter_map do |row, index|
      values = Array(row).map { |v| v.to_s.strip }
      next if columns.each_value.all? { |i| values[i].nil? || values[i].empty? }

      # +2: Kopfzeile plus 1-basierte Zählung, damit die Nummer der Zeile in der
      # Tabellenkalkulation entspricht.
      Row.new(number: index + 2, cells: values)
    end
  end

  # Encoding prüfen, BOM strippen, Zeilenenden vereinheitlichen — in dieser
  # Reihenfolge. Deutsches Excel schreibt standardmäßig Windows-1252, und schon
  # `sub!` wirft dagegen ArgumentError ("invalid byte sequence in UTF-8"), was
  # kein EncodingError ist und im 500er statt in einer Meldung endete.
  def normalized_content
    content = @csv_content.dup
    content.force_encoding('UTF-8') if content.encoding != Encoding::UTF_8

    unless content.valid_encoding?
      @errors << 'Datei-Encoding wird nicht unterstützt. Bitte die CSV als UTF-8 ' \
                 'speichern (in Excel: „CSV UTF-8 (durch Trennzeichen getrennt)").'
      return nil
    end

    content.sub!(/\A\u{FEFF}/, '')
    content.gsub!(/\r\n?/, "\n")
    content
  end

  # Trennzeichen aus der Kopfzeile ableiten. Gezählt wird nur dort, weil in den
  # Datenzeilen ein Komma auch im Namensfeld stehen kann.
  def detect_col_sep(content)
    header_line = content.lines.first.to_s
    COL_SEPS.max_by { |sep| header_line.count(sep) }
  end

  def resolve_columns(header)
    if header.blank?
      @errors << 'CSV-Header nicht erkannt. Die erste Zeile muss die Spaltenüberschriften ' \
                 '"Lizenznummer" und "E-Mailadresse" enthalten.'
      return nil
    end

    normalized = header.map { |h| h.to_s.strip.downcase.gsub(/\s+/, ' ') }
    columns = {
      lizenznummer: normalized.index { |h| LICENSE_ALIASES.include?(h) },
      email: normalized.index { |h| EMAIL_ALIASES.include?(h) }
    }

    missing = columns.select { |_, index| index.nil? }.keys
    if missing.any?
      labels = { lizenznummer: 'Lizenznummer', email: 'E-Mailadresse' }
      @errors << "CSV fehlen Pflichtspalten: #{missing.map { |f| labels[f] }.join(', ')}. " \
                 'Erwartet werden die Spaltenüberschriften "Lizenznummer" und "E-Mailadresse".'
      return nil
    end

    columns
  end

  # Trägt die Adressen ein und protokolliert jede verarbeitete Datenzeile in genau
  # einem Topf, sodass die vier Zahlen des Reports `total_rows` ergeben. In einer
  # Transaktion, damit ein unerwarteter Fehler nichts halb Angewandtes
  # zurücklässt, von dem der Report nie berichtet.
  def apply(rows, columns)
    report = { total_rows: rows.size, updated: [], skipped: [], not_found: [], invalid: [] }

    ActiveRecord::Base.transaction do
      referees = load_referees(rows, columns)

      rows.each { |row| apply_row(report, referees, row, columns) }
    end

    report
  end

  # Alle betroffenen Schiedsrichter in EINER Query. Zusammengeführte Dubletten
  # bleiben bewusst außen vor (canonical): Eine Adresse am aufgelösten Datensatz
  # erreicht niemanden mehr. Sie landen im Report unter not_found, dessen Label
  # deshalb „ohne aktiven Schiedsrichter" lautet und nicht „gibt es nicht".
  def load_referees(rows, columns)
    numbers = rows.filter_map { |row| license_number(row.cells[columns[:lizenznummer]]) }.uniq
    return {} if numbers.empty?

    Referee.canonical.where(lizenznummer: numbers).index_by(&:lizenznummer)
  end

  def apply_row(report, referees, row, columns)
    raw_number = row.cells[columns[:lizenznummer]].to_s.strip
    raw_email  = row.cells[columns[:email]].to_s.strip

    number = license_number(raw_number)
    if number.nil?
      report[:invalid] << { row: row.number, value: raw_number, reason: 'Lizenznummer ist keine Zahl' }
      return
    end

    referee = referees[number]
    if referee.nil?
      report[:not_found] << number
      return
    end

    if raw_email.blank?
      report[:invalid] << { row: row.number, value: raw_number, reason: 'E-Mailadresse fehlt' }
      return
    end

    unless raw_email.match?(URI::MailTo::EMAIL_REGEXP)
      report[:invalid] << { row: row.number, value: raw_email, reason: 'E-Mailadresse ist ungültig' }
      return
    end

    write_email(report, referee, raw_email, row.number)
  end

  def write_email(report, referee, email, line)
    if referee.email.present?
      reason = referee.email.casecmp?(email) ? 'identical' : 'other_email'
      report[:skipped] << entry(referee, line).merge(email: referee.email, csv_email: email, reason: reason)
      return
    end

    referee.email = email
    if referee.save
      report[:updated] << entry(referee, line).merge(email: email)
    else
      # Referee validiert die Adresse selbst nicht (das tut der Import oben), also
      # war hier der Stammdatensatz schon vorher ungültig — etwa ein Altbestand
      # ohne Vornamen. Deshalb Name und Lizenznummer mit in die Meldung: Der Fehler
      # sitzt im Profil, nicht in der Zeile.
      report[:invalid] << { row: line, value: "#{referee.lizenznummer} #{referee.vorname} #{referee.nachname}",
                            reason: referee.errors.full_messages.to_sentence }
    end
  end

  def entry(referee, line)
    { row: line, id: referee.id, lizenznummer: referee.lizenznummer,
      name: "#{referee.vorname} #{referee.nachname}" }
  end

  # Nur reine Ziffernfolgen gelten. Ein `to_i` würde aus "12a" still eine 12
  # machen und die Adresse an den falschen Schiedsrichter schreiben.
  def license_number(value)
    text = value.to_s.strip
    return nil unless text.match?(/\A\d+\z/)

    number = text.to_i
    number.positive? ? number : nil
  end
end
