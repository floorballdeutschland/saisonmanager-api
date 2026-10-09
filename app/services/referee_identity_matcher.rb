# Sucht zu Personenangaben moegliche Bestandsschiris. Gemeinsame Regel fuer den
# CSV-Kursimport (RefereeCourseImportService, der daraus den besten Treffer
# waehlt) und die oeffentliche Kursanmeldung (die Kandidaten nur als Hinweis
# fuer die RSK speichert und nie selbst zuordnet).
#
# Kandidat ist, wer bei Vor- und Nachname, bei Nachname und Geburtsdatum oder
# bei der E-Mail uebereinstimmt. Ein widersprechender Vorname schliesst aus
# (Zwillinge, api#685).
class RefereeIdentityMatcher
  UMLAUT_FOLD = { 'ä' => 'ae', 'ö' => 'oe', 'ü' => 'ue', 'ß' => 'ss' }.freeze
  HINT_LIMIT = 5

  # Hinweise fuer die RSK: Kandidaten ohne Vornamen-Widerspruch, als kleine
  # Hashes zum Speichern an der Anmeldung.
  def self.hints(vorname:, nachname:, geburtsdatum:, email:)
    attrs = { vorname: vorname.presence, nachname: nachname.presence, geburtsdatum: geburtsdatum,
              email: email.presence }
    candidates(attrs).includes(:club).to_a
                     .reject { |r| vorname_conflict?(attrs[:vorname], r.vorname) }
                     .first(HINT_LIMIT)
                     .map do |r|
      { 'id' => r.id, 'lizenznummer' => r.lizenznummer, 'vorname' => r.vorname, 'nachname' => r.nachname,
        'geburtsdatum' => r.geburtsdatum&.iso8601, 'club' => r.club&.name, 'lizenzstufe' => r.lizenzstufe }
    end
  end

  def self.candidates(csv_attrs)
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

  # Ein widersprechender Vorname schließt den Kandidaten aus, statt nur einen
  # Match-Punkt zu kosten. Zwillinge teilen Nachname, Geburtsdatum und Verein,
  # und die leeren Felder einer Neumeldung (Lizenznummer, oft E-Mail) zählen
  # symmetrisch als Treffer: Der Bruder kam damit auf 5 von 6 und lag weit über
  # der Schwelle. Beim Anwenden hätte `apply_master_fields` ihn auf den
  # Vornamen aus der Datei umbenannt und die Lizenz auf seine Nummer
  # geschrieben.
  #
  # Der Lizenznummer-Zweig oben bleibt unberührt: Eine getroffene Lizenznummer
  # ist die Identität, auch wenn der Vorname korrigiert wird.
  #
  # Bewusst keine Ausnahme für eine gleiche E-Mail-Adresse: Geschwister teilen
  # sich im Kursalter regelmäßig die Adresse eines Elternteils.
  def self.vorname_conflict?(csv_vorname, ref_vorname)
    return false if csv_vorname.blank? || ref_vorname.blank?

    csv_parts = vorname_parts(csv_vorname)
    ref_parts = vorname_parts(ref_vorname)
    return false if csv_parts.empty? || ref_parts.empty?

    # Kurz- und Rufformen bleiben ein Treffer, und zwar je Namensbestandteil:
    # „Nic" zu „Niclas", aber auch „Peter" zu „Hans-Peter", wo der Rufname
    # hinten steht. Der Präfixvergleich ist zeichengenau, „Luke" und „Lukas"
    # widersprechen sich also weiterhin.
    csv_parts.none? do |csv_part|
      ref_parts.any? do |ref_part|
        csv_part.start_with?(ref_part) || ref_part.start_with?(csv_part)
      end
    end
  end

  # Bestandteile des Vornamens in vergleichbarer Form. Schreibweisen sollen
  # keinen Widerspruch auslösen: Groß-/Kleinschreibung, Bindestrich gegen
  # Leerzeichen und die Umlaut-Umschrift („Juergen" gegen „Jürgen") fallen weg.
  #
  # Die Normalisierung nach NFC steht vor der Umlaut-Umschrift, weil macOS und
  # Excel für Mac Umlaute zerlegt schreiben (u + kombinierender Trema). Ohne
  # sie griffe die Zeichenklasse nicht, das Kombinationszeichen fiele weg und
  # „Jürgen" ergäbe „jurgen", was gegen „juergen" ein Widerspruch wäre. Der
  # zweite Durchgang über NFKD entfernt die übrigen Diakritika, damit „José"
  # und „Jose" dieselbe Person bleiben.
  def self.vorname_parts(value)
    folded = value.to_s.unicode_normalize(:nfc).downcase
                  .gsub(/[äöüß]/, UMLAUT_FOLD)
                  .unicode_normalize(:nfkd)
                  .gsub(/\p{Mn}/, '')
    folded.split(/[^[:alnum:]]+/).reject(&:empty?)
  end
end
