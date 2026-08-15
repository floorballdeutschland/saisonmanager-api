# lib/tasks/fix_keeper_names.rake
#
# Bereinigung der Freitext-Namen im Spielbericht: games.record_keeper_string
# (Schriftfuehrer) und games.time_keeper_string (Zeitnehmer).
#
# Beide Felder setzt das Frontend aus zwei Eingaben zu "Nachname, Vorname"
# zusammen und liest sie ueber split(', ') wieder auseinander. Die fruehere
# Fassung nutzte dafuer ein Template-Literal ohne Trim und ohne Behandlung
# fehlender Teile. Daraus sind zwei Muster im Bestand entstanden:
#
# 1) "undefined, Carolina"
#    Fehlte der Nachname, machte das Template-Literal aus undefined die
#    Zeichenkette "undefined". Sie steht seitdem so im Spielbericht.
#
# 2) "Ziegler, Carolina "
#    Ein versehentliches Leerzeichen am Ende der Eingabe wurde unveraendert
#    uebernommen.
#
# Die Ursache ist mit fe#289 behoben (personName in match-event-form). Dieser
# Task raeumt nur die Altbestaende auf.
#
# Bewusst konservativ: Der Task setzt ausschliesslich zusammen, was schon da
# ist. Er erfindet keinen Nachnamen und loescht keinen Namen, der nur aus
# einem Teil besteht. Bleibt nach dem Aufraeumen nichts uebrig (etwa bei
# "undefined, "), wird das Feld auf NULL gesetzt -- ein leeres Feld ist
# ehrlicher als ein erfundener Name.
#
# Dry-Run (Standard):
#   bundle exec rails keeper_names:report
#   bundle exec rails keeper_names:cleanup
# Ausfuehren:
#   bundle exec rails keeper_names:cleanup DRY_RUN=false
#
# Idempotent: Ein zweiter Lauf findet nichts mehr.

namespace :keeper_names do
  def keeper_columns
    %w[record_keeper_string time_keeper_string]
  end

  # "undefined" nur als Nachname, also am Anfang und direkt vor dem
  # Trennzeichen. Ein Name, der das Wort mitten im Text traegt, bleibt
  # unangetastet.
  def keeper_undefined_prefix
    'undefined,'
  end

  def keeper_dry_run?
    ENV['DRY_RUN'] != 'false'
  end

  # Dieselbe Regel wie personName im Frontend: Kommata raus (das Komma ist das
  # Trennzeichen), beide Teile trimmen, das Trennzeichen nur behalten, solange
  # ein Vorname da ist.
  def keeper_normalize(value)
    return nil if value.nil?

    last, first = value.split(', ', 2)
    last = last.to_s.delete(',').strip
    first = first.to_s.delete(',').strip
    last = '' if last == 'undefined'
    first = '' if first == 'undefined'

    return nil if last.empty? && first.empty?
    return last if first.empty?

    "#{last}, #{first}"
  end

  desc 'Bestandsaufnahme der Schriftfuehrer- und Zeitnehmer-Namen (nur lesend).'
  task report: :environment do
    keeper_columns.each do |col|
      undefined_n = Game.where("#{col} LIKE ?", "#{keeper_undefined_prefix}%").count
      space_n = Game.where("#{col} ~ '\\s$'").count
      puts "#{col}: beginnt mit \"undefined,\" -> #{undefined_n} | endet auf Leerzeichen -> #{space_n}"

      Game.where("#{col} LIKE ? OR #{col} ~ '\\s$'", "#{keeper_undefined_prefix}%")
          .limit(5).each do |g|
        puts "    Spiel #{g.id}: #{g[col].inspect} -> #{keeper_normalize(g[col]).inspect}"
      end
    end
  end

  desc 'Raeumt "undefined" und Leerzeichen am Ende aus den Keeper-Namen. DRY_RUN=false zum Ausfuehren.'
  task cleanup: :environment do
    dry = keeper_dry_run?
    puts dry ? '=== DRY RUN, es wird nichts geschrieben (DRY_RUN=false zum Ausfuehren) ===' : '=== SCHREIBLAUF ==='

    keeper_columns.each do |col|
      changed = 0
      cleared = 0
      untouched = 0

      Game.where("#{col} LIKE ? OR #{col} ~ '\\s$'", "#{keeper_undefined_prefix}%")
          .find_each do |game|
        before = game[col]
        after = keeper_normalize(before)

        if before == after
          untouched += 1
          next
        end

        cleared += 1 if after.nil?
        changed += 1
        puts "  Spiel #{game.id}: #{before.inspect} -> #{after.inspect}"
        game.update_columns(col => after) unless dry
      end

      puts "#{col}: #{changed} geaendert (davon #{cleared} geleert), #{untouched} unveraendert"
    end

    puts 'Nichts geschrieben (Dry Run).' if dry
  end
end
