# players.birthdate war historisch eine varchar-Spalte. Alle aktuellen
# Schreibpfade liefern ISO (JJJJ-MM-TT); im Altbestand können Leerstrings,
# MariaDB-Nulldaten ("0000-00-00") oder deutsches Format (TT.MM.JJJJ) stehen.
# Diese Migration normalisiert deterministisch und bricht bei allem ab, was
# nicht eindeutig lesbar ist – echte Geburtsdaten werden nie still genullt.
# Vorab-Analyse: rake players:birthdate_format_report
class ChangePlayersBirthdateToDate < ActiveRecord::Migration[7.1]
  ISO_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
  GERMAN_FORMAT = /\A\d{1,2}\.\d{1,2}\.\d{4}\z/

  # Liefert den normalisierten ISO-String, nil (kein Datum vorhanden)
  # oder :invalid (nicht eindeutig lesbar).
  def self.normalize(value)
    str = value.to_s.strip
    return nil if str.empty? || str.start_with?('0000')

    if str.match?(ISO_FORMAT)
      parse_or_invalid(str, '%Y-%m-%d')
    elsif str.match?(GERMAN_FORMAT)
      parse_or_invalid(str, '%d.%m.%Y')
    else
      :invalid
    end
  end

  def self.parse_or_invalid(str, format)
    Date.strptime(str, format).iso8601
  rescue ArgumentError
    :invalid
  end

  def up
    invalid = normalize_rows!
    if invalid.any?
      sample = invalid.first(20).map { |id, raw| "##{id}: #{raw.inspect}" }.join(', ')
      raise "players.birthdate enthält #{invalid.size} nicht lesbare Werte – bitte vorab " \
            "bereinigen (rake players:birthdate_format_report). Beispiele: #{sample}"
    end

    change_column :players, :birthdate, :date, using: "NULLIF(btrim(birthdate), '')::date"
  end

  def down
    change_column :players, :birthdate, :string
  end

  private

  def normalize_rows!
    invalid = []
    select_rows('SELECT id, birthdate FROM players WHERE birthdate IS NOT NULL').each do |id, raw|
      normalized = self.class.normalize(raw)
      if normalized == :invalid
        invalid << [id, raw]
      elsif normalized != raw
        quoted = normalized.nil? ? 'NULL' : connection.quote(normalized)
        execute("UPDATE players SET birthdate = #{quoted} WHERE id = #{id.to_i}")
      end
    end
    invalid
  end
end
