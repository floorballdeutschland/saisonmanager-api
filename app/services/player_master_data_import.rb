require 'csv'

# Trägt fehlende Stammdaten aus einer CSV in bestehende Spielerprofile ein.
#
# Gegenstück zum CSV-Export der Vereinssicht („Meine Spieler*innen"): Der Verein
# lädt seinen Bestand herunter, füllt die Lücken in der Tabellenkalkulation und
# lädt dieselbe Datei wieder hoch. Deshalb wird das Export-Format gelesen, und
# deshalb ist die Spieler-ID der Schlüssel — sie steht im Export und ist die
# einzige Angabe, die eine Zeile eindeutig einem Profil zuordnet. Ein Abgleich
# über Name und Geburtsdatum träfe bei Namensgleichheit im selben Verein die
# falsche Person, und genau dort wäre der Schaden am größten.
#
# Geschrieben wird ausschließlich, wo im Profil noch nichts steht. Die CSV ist
# eine Ergänzung des Bestands, nicht die Quelle der Wahrheit: Wer seine Adresse
# gepflegt oder über einen Änderungsantrag korrigiert hat, darf sie nicht durch
# einen älteren Vereinsexport verlieren — und das fiele niemandem auf, weil der
# alte Wert dabei spurlos verschwindet. Dieselbe Regel wie in
# RefereeEmailImport, hier auf mehrere Felder ausgedehnt.
#
# Die Rechteteilung entspricht der Maske daneben: Die E-Mail-Adresse pflegt der
# Verein selbst (`update_email`), Geburtsdatum, Geschlecht und Nationalität
# ändert nur Admin/SBK (`update_player`) — für den Verein führt der Weg dorthin
# über den Änderungsantrag. Der Import darf dieser Trennung keine Hintertür
# geben, auch nicht für ein leeres Feld: Ein Geburtsdatum, das nie geprüft
# wurde, wiegt genauso schwer wie ein geändertes.
class PlayerMasterDataImport
  # Eine Datenzeile mit ihrer Nummer in der Datei. Die Nummer wird mitgeführt und
  # nicht aus dem Schleifenindex abgeleitet: Verworfene Leerzeilen verschieben den
  # Index, und der Report zeigte ab der ersten Leerzeile auf die falsche Zeile.
  Row = Struct.new(:number, :cells, keyword_init: true)

  # Obergrenze der verarbeiteten Datenzeilen. Der Import läuft in EINER
  # Transaktion; ohne Grenze könnte eine versehentlich hochgeladene Großdatei in
  # ein Timeout laufen, und der Rollback nähme dann auch den Report mit — der
  # Verein sähe nur einen Fehler und wüsste nicht, was geschrieben wurde. Der
  # größte Vereinsbestand liegt deutlich darunter.
  MAX_DATA_ROWS = 5_000

  # Kandidaten für das Spaltentrennzeichen. Der eigene Export schreibt Semikolon
  # (deutsches Excel), andere Werkzeuge Komma oder Tabulator; ausgezählt wird die
  # Kopfzeile. Enthält sie keines der drei, bleibt es beim ersten Kandidaten, und
  # die Datei scheitert an der fehlenden ID-Spalte.
  COL_SEPS = [';', ',', "\t"].freeze

  # Spaltennamen, unter denen die Felder erkannt werden. Aufgelöst wird über den
  # Namen und nicht über die Position: Wer in Excel eine Spalte einfügt oder
  # verschiebt, soll nicht eine Datei bekommen, die stumm die falschen Werte
  # zuordnet. Der jeweils erste Eintrag ist die Überschrift des eigenen Exports.
  ALIASES = {
    id: ['id', 'spieler-id', 'spieler id', 'spielerid', 'player_id'],
    email: ['e-mail', 'e-mailadresse', 'e-mail-adresse', 'e-mail adresse', 'email', 'emailadresse', 'mail'],
    birthdate: %w[geburtsdatum geburtstag birthdate],
    gender: %w[geschlecht gender],
    nation_id: ['nation-id', 'nation id', 'nationid', 'nation_id']
  }.freeze

  # Felder, die nur mit dem Recht `update_player` (Admin/SBK) nachgetragen
  # werden. Die E-Mail-Adresse fehlt hier bewusst: Sie ist das Feld, das der
  # Verein in dieser Maske ohnehin pflegt.
  MASTER_DATA_FIELDS = %i[birthdate gender nation_id].freeze

  GENDERS = {
    'm' => 'M', 'männlich' => 'M', 'maennlich' => 'M', 'male' => 'M',
    'w' => 'W', 'weiblich' => 'W', 'f' => 'W', 'female' => 'W',
    'd' => 'D', 'divers' => 'D', 'diverse' => 'D'
  }.freeze

  attr_reader :errors

  # players: die Profile des Vereins, gegen die abgeglichen wird (inkl.
  #          deaktivierter — der Export nennt sie nicht, eine handgeschriebene
  #          Datei darf sie aber erreichen, und ein „nicht gefunden" wäre dort
  #          die falsche Auskunft).
  # email_writable_ids: die IDs, deren Adresse dieser Account schreiben darf
  #          (can_manage_player?). Für VM und TM ist das die ganze Liste, für die
  #          SBK nicht — siehe PlayersController#vm_players_index.
  # may_write_master_data: darf dieser Account Geburtsdatum, Geschlecht und
  #          Nationalität nachtragen (`update_player`)?
  # actor_id: wird als `updated_by` in die geschriebenen Profile eingetragen.
  def initialize(csv_content:, players:, email_writable_ids:, may_write_master_data:, actor_id: nil)
    @csv_content = csv_content.to_s
    @players_by_id = players.index_by(&:id)
    @email_writable_ids = email_writable_ids.to_set
    @may_write_master_data = may_write_master_data
    @actor_id = actor_id
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
      @errors << 'Die CSV enthält keine Datenzeilen.'
      return nil
    end

    if rows.size > MAX_DATA_ROWS
      @errors << "Die Datei enthält #{rows.size} Datenzeilen, verarbeitet werden höchstens " \
                 "#{MAX_DATA_ROWS}. Bitte in mehreren Dateien hochladen."
      return nil
    end

    [rows, columns]
  rescue CSV::MalformedCSVError => e
    @errors << "Die CSV konnte nicht gelesen werden: #{e.message}"
    nil
  rescue EncodingError => e
    @errors << "Datei-Encoding wird nicht unterstützt (bitte als UTF-8 speichern): #{e.message}"
    nil
  end

  # Encoding prüfen, BOM strippen, Zeilenenden vereinheitlichen — in dieser
  # Reihenfolge. Der eigene Export schreibt UTF-8 mit BOM, deutsches Excel
  # speichert beim Zurückschreiben aber gern Windows-1252, und schon `sub!` wirft
  # dagegen ArgumentError ("invalid byte sequence in UTF-8"), was kein
  # EncodingError ist und im 500er statt in einer Meldung endete.
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

  # Pflicht ist nur die ID-Spalte; von den Wertspalten muss mindestens eine da
  # sein, sonst gäbe es nichts einzutragen und der Lauf endete mit einem Report
  # voller Nullen, der wie ein Fehlschlag aussieht.
  def resolve_columns(header)
    if header.blank?
      @errors << 'CSV-Header nicht erkannt. Die erste Zeile muss die Spaltenüberschriften des ' \
                 'Exports enthalten.'
      return nil
    end

    normalized = header.map { |h| h.to_s.strip.downcase.gsub(/\s+/, ' ') }
    columns = ALIASES.filter_map do |field, aliases|
      index = normalized.index { |h| aliases.include?(h) }
      [field, index] if index
    end.to_h

    if columns[:id].nil?
      @errors << 'Der CSV fehlt die Spalte "ID". Bitte den Export dieser Seite als Vorlage ' \
                 'verwenden — die ID ordnet jede Zeile ihrem Profil zu.'
      return nil
    end

    if (columns.keys - [:id]).empty?
      @errors << 'Die CSV enthält keine Spalte mit nachtragbaren Angaben. Erwartet wird ' \
                 'mindestens eine der Spalten "E-Mail", "Geburtsdatum", "Geschlecht" oder ' \
                 '"Nation-ID".'
      return nil
    end

    columns
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

  # Trägt die Werte ein und protokolliert jede verarbeitete Datenzeile in genau
  # einem Topf, sodass die vier Zahlen des Reports `total_rows` ergeben. Eine
  # Zeile, in der ein Feld geschrieben und ein zweites übersprungen wurde, zählt
  # als geschrieben; die Gründe der übersprungenen Felder hängen am Eintrag.
  #
  # In einer Transaktion, damit ein unerwarteter Fehler nichts halb Angewandtes
  # zurücklässt, von dem der Report nie berichtet.
  def apply(rows, columns)
    report = { total_rows: rows.size, updated: [], skipped: [], not_found: [], invalid: [] }

    ActiveRecord::Base.transaction do
      rows.each { |row| apply_row(report, row, columns) }
    end

    report
  end

  def apply_row(report, row, columns)
    raw_id = row.cells[columns[:id]].to_s.strip
    id = raw_id.match?(/\A\d+\z/) ? raw_id.to_i : nil
    if id.nil? || id.zero?
      report[:invalid] << { row: row.number, value: raw_id, reason: 'ID ist keine Zahl' }
      return
    end

    player = @players_by_id[id]
    if player.nil?
      report[:not_found] << { row: row.number, id: id }
      return
    end

    values, skipped, invalid = classify(player, row, columns)

    if invalid.any?
      # Eine Zeile mit unbrauchbarem Wert wird gar nicht geschrieben, auch nicht
      # in ihren gültigen Feldern: Ein halb angewandter Datensatz wäre für den
      # Verein nicht von einem vollständigen zu unterscheiden, und die Datei
      # nachzubessern und erneut hochzuladen ist ungefährlich (geschriebene
      # Felder sind dann belegt und werden übersprungen).
      report[:invalid] << { row: row.number, id: player.id, name: player_name(player),
                            value: invalid.values.join(', '),
                            reason: invalid.map { |field, _| invalid_reason(field) }.join(', ') }
      return
    end

    if values.empty?
      report[:skipped] << { row: row.number, id: player.id, name: player_name(player),
                            reasons: skipped.presence || { row: 'empty' } }
      return
    end

    write(report, player, values, skipped, row.number)
  end

  # Teilt die Wertspalten der Zeile in „schreiben", „überspringen" und
  # „unbrauchbar" auf. Der Reihenfolge nach: leere Zelle (nichts angeboten),
  # fehlendes Recht, belegtes Feld, ungültiger Wert.
  #
  # „Belegt" wird VOR der Gültigkeit geprüft: Steht im Profil schon eine
  # Adresse, ist ein Tippfehler in der CSV-Zelle ohne Folge, und ein Fehler
  # dafür wäre eine Aufforderung, eine Datei zu korrigieren, aus der gar nichts
  # übernommen wird.
  def classify(player, row, columns)
    values = {}
    skipped = {}
    invalid = {}

    columns.each do |field, index|
      next if field == :id

      raw = row.cells[index].to_s.strip
      next if raw.empty?

      if MASTER_DATA_FIELDS.include?(field) && !@may_write_master_data
        skipped[field] = 'no_permission'
        next
      end
      if field == :email && !@email_writable_ids.include?(player.id)
        skipped[field] = 'no_permission'
        next
      end

      if player.public_send(field).present?
        skipped[field] = current_value(player, field).to_s.casecmp?(normalize(field, raw).to_s) ? 'identical' : 'already_set'
        next
      end

      normalized = normalize(field, raw)
      if normalized.nil?
        invalid[field] = raw
      else
        values[field] = normalized
      end
    end

    [values, skipped, invalid]
  end

  # Der gespeicherte Wert in der Schreibweise, in der auch die CSV-Zelle
  # normalisiert wird — sonst gälte ein „M" gegen „m" als abweichend und der
  # Report meldete einen Konflikt, wo keiner ist.
  def current_value(player, field)
    value = player.public_send(field)
    field == :birthdate ? value.to_s : value
  end

  def normalize(field, raw)
    case field
    when :email     then raw.match?(URI::MailTo::EMAIL_REGEXP) ? raw : nil
    when :gender    then GENDERS[raw.downcase]
    when :nation_id then raw.match?(/\A\d+\z/) && raw.to_i.positive? ? raw.to_i : nil
    when :birthdate then parse_date(raw)
    end
  end

  # Nur die beiden Schreibweisen, die hier real vorkommen: das deutsche Format
  # des eigenen Exports und ISO (so schreibt es Excel nach einer Umformatierung).
  # Bewusst kein Date.parse — das liest „01.02.2010" je nach Eingabe auch als
  # Februar-Tag und macht aus einem Vertipper still ein falsches Geburtsdatum.
  def parse_date(raw)
    match = raw.match(%r{\A(\d{1,2})[./](\d{1,2})[./](\d{4})\z}) ||
            raw.match(/\A(\d{4})-(\d{1,2})-(\d{1,2})\z/)
    return nil unless match

    parts = match.captures.map(&:to_i)
    year, month, day = raw.include?('-') ? parts : parts.reverse
    date = Date.new(year, month, day)
    date <= Date.current ? date.to_s : nil
  rescue Date::Error
    nil
  end

  def write(report, player, values, skipped, line)
    values.each { |field, value| player.public_send(:"#{field}=", value) }
    player.updated_by = @actor_id if @actor_id

    if player.save
      report[:updated] << { row: line, id: player.id, name: player_name(player),
                            fields: values.transform_values(&:to_s), skipped: skipped }
    else
      # Der Datensatz war schon vorher unvollständig — etwa ein Altbestand ohne
      # Nationalität, die das Modell verlangt. Deshalb Name und ID mit in die
      # Meldung: Der Fehler sitzt im Profil, nicht in der Zeile.
      report[:invalid] << { row: line, id: player.id, name: player_name(player),
                            value: values.values.join(', '),
                            reason: player.errors.full_messages.to_sentence }
    end
  end

  INVALID_REASONS = {
    email: 'E-Mail-Adresse ist ungültig',
    gender: 'Geschlecht muss m, w oder d sein',
    nation_id: 'Nation-ID ist keine Zahl',
    birthdate: 'Geburtsdatum muss TT.MM.JJJJ sein und darf nicht in der Zukunft liegen'
  }.freeze

  def invalid_reason(field)
    INVALID_REASONS[field]
  end

  def player_name(player)
    "#{player.last_name}, #{player.first_name}"
  end
end
