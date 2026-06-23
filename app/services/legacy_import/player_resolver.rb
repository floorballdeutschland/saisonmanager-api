# frozen_string_literal: true

module LegacyImport
  # Bildet alte global_spieler-IDs auf die IDs der neuen `players`-Tabelle ab,
  # gematcht über (Nachname, Vorname, Geburtsdatum). Reine Logik – der Index wird
  # vom Aufrufer aus Player-Datensätzen gebaut, damit hier ohne DB testbar.
  #
  # Hintergrund: Im PoC wurde players.player_id als alte id_spieler durchgereicht
  # (falsche Identitäten in Scorerlisten). Mit diesem Remap zeigen die Lineups auf
  # die echten Player-Records.
  module PlayerResolver
    module_function

    # Normalisiert einen Namensteil für den Vergleich (Groß/Klein, Rand-Whitespace).
    def norm(str)
      str.to_s.strip.downcase
    end

    # Geburtsdatum auf 'YYYY-MM-DD' vereinheitlichen (alt: Date/String, neu: String).
    def norm_date(val)
      val.to_s.strip[0, 10]
    end

    def key(last, first, birthdate)
      "#{norm(last)}|#{norm(first)}|#{norm_date(birthdate)}"
    end

    # rows: Enumerable von [last_name, first_name, birthdate, id].
    # Liefert { key => id }. Mehrdeutige Schlüssel (Namensgleichheit + gleiches
    # Geburtsdatum) werden gezählt und nicht eindeutig aufgelöst.
    def build_index(rows)
      index = {}
      ambiguous = Set.new
      rows.each do |last, first, birthdate, id|
        next if birthdate.to_s.strip.empty?

        k = key(last, first, birthdate)
        if index.key?(k) && index[k] != id
          ambiguous << k
        else
          index[k] = id
        end
      end
      ambiguous.each { |k| index.delete(k) } # mehrdeutige Treffer verwerfen
      index
    end

    # spieler_map: { "old_id" => { 'name', 'vorname', 'geb_datum' } }.
    # Liefert { old_id(Integer) => new_player_id }. Nur eindeutige Treffer.
    def resolve(spieler_map, index)
      result = {}
      (spieler_map || {}).each do |old_id, data|
        k = key(data['name'], data['vorname'], data['geb_datum'])
        pid = index[k]
        result[old_id.to_i] = pid if pid
      end
      result
    end
  end
end
