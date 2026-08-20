require 'csv'

# Trägt E-Mail-Adressen aus einer CSV in bestehende Schiedsrichter-Profile ein.
#
# Geschrieben wird ausschließlich dort, wo noch keine Adresse steht: Die CSV ist
# eine Ergänzung der Bestandsdaten, nicht die Quelle der Wahrheit. Wer seine
# Adresse selbst im Profil gepflegt oder über den RSK korrigiert hat, darf sie
# nicht durch einen älteren Verbandsexport verlieren — und das fiele niemandem
# auf, weil die alte Adresse dabei spurlos verschwindet.
class RefereeEmailImport
  # Kopfzeilen-Namen, unter denen die beiden Spalten erkannt werden. Aufgelöst
  # wird über den Namen und nicht über die Position: Ein Export mit vertauschten
  # Spalten würde sonst Lizenznummern als Adressen lesen und die Datei komplett
  # als „ungültig" abweisen, ohne den Grund zu benennen.
  LICENSE_ALIASES = ['lizenznummer', 'lizenz-nr.', 'lizenz-nr', 'lizenznr.', 'lizenznr',
                     'lizenz nr.', 'lizenz nr'].freeze
  EMAIL_ALIASES = ['e-mailadresse', 'e-mail-adresse', 'e-mail adresse', 'e-mailadresse sr',
                   'e-mail', 'email', 'emailadresse', 'mail'].freeze

  # Kandidaten für das Spaltentrennzeichen. Deutsches Excel schreibt Semikolon,
  # andere Werkzeuge Komma oder Tab — geraten wird nicht, sondern die Kopfzeile
  # ausgezählt.
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

    col_sep = detect_col_sep(content)
    raw = CSV.parse(content, col_sep: col_sep, row_sep: "\n", skip_blanks: true)
    header = raw.shift

    columns = resolve_columns(header)
    return nil if columns.nil?

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

  # Trägt die Adressen ein und protokolliert jede Zeile in genau einem Topf.
  # In einer Transaktion, damit ein unerwarteter Fehler nichts halb Angewandtes
  # zurücklässt, von dem der Report nie berichtet.
  def apply(rows, columns)
    report = { total_rows: rows.size, updated: [], skipped: [], not_found: [], invalid: [] }

    ActiveRecord::Base.transaction do
      referees = load_referees(rows, columns)

      rows.each_with_index do |row, index|
        # +2: Kopfzeile plus 1-basierte Zählung, damit die Nummer der Zeile in
        # der Tabellenkalkulation entspricht.
        apply_row(report, referees, row, columns, index + 2)
      end
    end

    report
  end

  # Alle betroffenen Schiedsrichter in EINER Query. Zusammengeführte Dubletten
  # bleiben bewusst außen vor (canonical): Eine Adresse am aufgelösten Datensatz
  # erreicht niemanden mehr.
  def load_referees(rows, columns)
    numbers = rows.filter_map { |row| license_number(row[columns[:lizenznummer]]) }.uniq
    return {} if numbers.empty?

    Referee.canonical.where(lizenznummer: numbers).index_by(&:lizenznummer)
  end

  def apply_row(report, referees, row, columns, line)
    raw_number = row[columns[:lizenznummer]].to_s.strip
    raw_email  = row[columns[:email]].to_s.strip

    number = license_number(raw_number)
    if number.nil?
      report[:invalid] << { row: line, value: raw_number, reason: 'Lizenznummer ist keine Zahl' }
      return
    end

    referee = referees[number]
    if referee.nil?
      report[:not_found] << number
      return
    end

    if raw_email.blank?
      report[:invalid] << { row: line, value: raw_number, reason: 'E-Mailadresse fehlt' }
      return
    end

    unless raw_email.match?(URI::MailTo::EMAIL_REGEXP)
      report[:invalid] << { row: line, value: raw_email, reason: 'E-Mailadresse ist ungültig' }
      return
    end

    write_email(report, referee, raw_email, line)
  end

  def write_email(report, referee, email, line)
    if referee.email.present?
      reason = referee.email.casecmp?(email) ? 'identical' : 'other_email'
      report[:skipped] << entry(referee).merge(email: referee.email, csv_email: email, reason: reason)
      return
    end

    referee.email = email
    if referee.save
      report[:updated] << entry(referee).merge(email: email)
    else
      report[:invalid] << { row: line, value: email, reason: referee.errors.full_messages.to_sentence }
    end
  end

  def entry(referee)
    { id: referee.id, lizenznummer: referee.lizenznummer, name: "#{referee.vorname} #{referee.nachname}" }
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
