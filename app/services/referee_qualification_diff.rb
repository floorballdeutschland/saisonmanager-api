# Vergleicht die Zusatzqualifikationen eines Schiedsrichters vor und nach einem
# Speichern und liefert die Änderungen für die Benachrichtigungsmail.
#
# Nötig, weil `referees#update` die Zuordnungen nicht einzeln pflegt, sondern
# komplett neu setzt (destroy_all + create). Dirty-Tracking gibt es deshalb
# nicht: Jede Zeile ist nach dem Speichern neu, auch die unveränderten. Ohne
# diesen Vergleich ginge bei jedem Speichern der Schiri-Maske eine Mail raus,
# selbst wenn nur der Nachname korrigiert wurde.
#
# Ein Wegfall ist ausdrücklich KEINE Änderung im Sinne dieser Mail: Gemeldet
# werden neue und inhaltlich geänderte Qualifikationen. Wer eine Qualifikation
# verliert (Ablauf, Korrektur eines Fehleintrags), erfährt das nicht per Mail —
# eine „Dir wurde etwas weggenommen"-Mail wäre ohne Begründung, die das System
# nicht kennt, mehr Verunsicherung als Information.
module RefereeQualificationDiff
  # before/after: { referee_qualification_type_id => valid_until (Date oder nil) }
  #
  # Rückgabe: Array aus { name:, valid_until:, kind: :added | :updated },
  # sortiert nach Qualifikationsname, damit die Mail eine stabile Reihenfolge
  # hat.
  def self.changes(before:, after:)
    changed = after.filter_map do |type_id, valid_until|
      next [type_id, valid_until, :added] unless before.key?(type_id)
      next [type_id, valid_until, :updated] if before[type_id] != valid_until

      nil
    end
    return [] if changed.empty?

    names = RefereeQualificationType.where(id: changed.map(&:first)).pluck(:id, :name).to_h
    benannt = changed.map do |type_id, valid_until, kind|
      { name: names[type_id] || 'Zusatzqualifikation', valid_until: valid_until, kind: kind }
    end
    benannt.sort_by { |change| change[:name] }
  end
end
