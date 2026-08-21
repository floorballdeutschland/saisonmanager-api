# Entfernt Leerzeichen am Rand von Vorname/Nachname aus dem Bestand (api#496).
#
# HINTERGRUND
#
# Transfer/Freigabe verglich Namen bisher nur mit LOWER(), ohne den Rand zu
# ignorieren. Ein Profil mit einem Leerzeichen am Namensende (z.B. "Daniel ")
# fand darüber nie einen exakten Treffer, obwohl der abgebende oder aufnehmende
# Verein den richtigen Namen eingegeben hat. Player#strip_names verhindert das
# jetzt bei jedem Speichern; dieser Task räumt den Bestand einmalig auf.
#
# Was der Task an der Auflösung ändert: Zwei Profile, die sich nur im Rand
# unterschieden ("Daniel" und "Daniel "), waren vorher zwei verschiedene Namen
# und sind hinterher derselbe. Die Suche (Player.with_exact_name) ignoriert den
# Rand schon vor dem Trimmen, gibt bei mehreren Treffern das älteste Profil
# zurück und ändert diese Antwort durch den Lauf also nicht. Auf der Datenbank
# liegt aber kein Unique-Index über Name und Geburtsdatum: Aus zwei vorher
# unterscheidbaren Datensätzen können zwei identische werden. Die eigentliche
# Auflösung ist die Dublettenzusammenführung, nicht dieser Task.
#
# AUFRUF
#
#   rake players:report_untrimmed_names   # nur lesend
#   rake players:trim_names               # Vorschau (Dry-Run, Default)
#   DRY_RUN=false rake players:trim_names  # ausführen
#
# Ein Lauf ist idempotent: Beim zweiten Mal findet er nichts mehr. Andere
# Schreibwege bleiben davon unberührt -- `save!(validate: false)`, `update_column`
# und die rohen INSERTs der Altdaten-Importe laufen an Player#strip_names vorbei
# und können neuen Rand anlegen.

namespace :players do
  def players_trim_dry_run?
    ENV['DRY_RUN'] != 'false'
  end

  # Nur die Spalten, die wirklich Rand tragen. `to_s.strip` über beide Namen
  # schriebe aus einem NULL-Vornamen ein '' -- eine stille Änderung an einem
  # Datensatz, den der Task nur mitgelesen hat, weil der Nachname gepolstert war.
  def players_name_trim_changes(player)
    %i[first_name last_name].each_with_object({}) do |feld, changes|
      wert = player[feld]
      next unless wert.is_a?(String)

      getrimmt = wert.strip
      changes[feld] = getrimmt unless getrimmt == wert
    end
  end

  desc 'Zeigt Spielerprofile mit Leerzeichen am Rand von Vor- oder Nachname'
  task report_untrimmed_names: :environment do
    scope = Player.with_padded_name
    puts "== Profile mit Leerzeichen am Namensrand: #{scope.count} =="
    scope.find_each do |player|
      puts "  #{player.id}\t#{player.first_name.inspect} #{player.last_name.inspect}"
    end
  end

  desc 'Trimmt Leerzeichen am Rand von Vor- und Nachname (Dry-Run per Default)'
  task trim_names: :environment do
    dry = players_trim_dry_run?
    puts dry ? '=== VORSCHAU (DRY_RUN) ===' : '=== SCHARF (DRY_RUN=false) ==='

    fixed = 0

    Player.with_padded_name.find_each do |player|
      changes = players_name_trim_changes(player)
      next if changes.empty?

      vorher = changes.keys.map { |feld| player[feld] }
      puts "  #{player.id}\t#{changes.keys.join(', ')}: #{vorher.inspect} → #{changes.values.inspect}"
      # update_columns statt save: der Bestand kann anderswo bereits ungueltig
      # sein (fehlende nation_id o.ae.), das darf das Trimmen nicht blockieren.
      player.update_columns(changes) unless dry
      fixed += 1
    end

    puts "\nGetrimmt: #{fixed}"
    puts "Nichts geschrieben. Mit DRY_RUN=false ausfuehren." if dry
  end
end
