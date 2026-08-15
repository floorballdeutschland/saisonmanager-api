# lib/tasks/fix_keeper_names.rake
#
# Bereinigung der Freitext-Namen im Spielbericht: games.record_keeper_string
# (Schriftfuehrer) und games.time_keeper_string (Zeitnehmer).
#
# Beide Felder setzt das Frontend aus zwei Eingaben zu "Nachname, Vorname"
# zusammen und liest sie ueber split(', ') wieder auseinander. Die fruehere
# Fassung nutzte ein Template-Literal ohne Trim und ohne Behandlung fehlender
# Teile. Daraus sind zwei Muster im Bestand entstanden, beide symmetrisch:
#
# 1) "undefined" als fehlender Namensteil
#    Fehlte der Nachname, entstand "undefined, Carolina"; fehlte der Vorname,
#    entstand "Ziegler, undefined". Auf Prod (15.08.2026) 128 bzw. 149
#    Eintraege je Spalte, knapp die Haelfte davon in der Vornamen-Form.
#
# 2) Nicht getrimmte Eingaben
#    Ein Leerzeichen landete unveraendert in der Datenbank, am Ende
#    (1408/1346), am Anfang (21/17) und vor dem Trennkomma (495/505).
#
# Die Ursache ist mit fe#289 behoben (personName in match-event-form). Dieser
# Task raeumt nur die Altbestaende auf.
#
# BEWUSST OHNE SQL-VORAUSWAHL: Die erste Fassung suchte per
# LIKE 'undefined,%' OR ~ '\s$'. Das uebersah die Haelfte der undefined-Faelle
# (die Vornamen-Form ist am Zeilenanfang nicht verankert) und alle 1000
# Eintraege mit Leerzeichen vor dem Komma. Die Regel vollstaendig in SQL
# nachzubilden ist fehleranfaellig; fuer einen einmaligen Lauf ueber knapp
# 38.000 gesetzte Werte je Spalte ist der Vollscan mit Vergleich in Ruby die
# billigere Wahrheit. Was sich nicht aendert, wird nicht angefasst.
#
# Bewusst konservativ: Der Task setzt ausschliesslich zusammen, was schon da
# ist. Er erfindet keinen Nachnamen und loescht keinen Namen, der nur aus
# einem Teil besteht. Bleibt nichts uebrig, wird das Feld geleert -- ein leeres
# Feld ist ehrlicher als ein erfundener Name. Geleert heisst leere Zeichenkette,
# nicht NULL: So schreibt es auch das Frontend, und bereits leere Zeilen bleiben
# damit unangetastet.
#
# Dry-Run (Standard):
#   bundle exec rails keeper_names:report
#   bundle exec rails keeper_names:cleanup
# Ausfuehren:
#   bundle exec rails keeper_names:cleanup DRY_RUN=false

namespace :keeper_names do
  def keeper_columns
    %w[record_keeper_string time_keeper_string]
  end

  def keeper_dry_run?
    ENV['DRY_RUN'] != 'false'
  end

  # Aussen liegende Leerzeichen entfernen, und zwar dieselben wie das
  # Frontend: JavaScripts trim() erfasst auch das geschuetzte Leerzeichen
  # (U+00A0), Rubys strip nicht. [[:space:]] schliesst es ein. Ohne das bliebe
  # ein aus Word kopierter Name hier liegen, waehrend das Frontend ihn kuenftig
  # putzt.
  def keeper_strip(str)
    str.gsub(/\A[[:space:]]+|[[:space:]]+\z/, '')
  end

  # Dieselbe Regel wie personName im Frontend, mit einer Ausnahme: Hier kommt
  # der bereits zusammengesetzte Wert an, nicht die beiden Eingaben. "undefined"
  # muss deshalb als Namensteil erkannt werden, im Frontend kann es gar nicht
  # erst entstehen.
  #
  # Getrennt wird am ERSTEN Komma, nicht an ", ": Ein Wert ohne Leerzeichen
  # nach dem Komma zerfiel sonst nicht, landete komplett im Nachnamen und
  # verlor dort sein Komma ("undefined,Carolina" -> "undefinedCarolina").
  def keeper_normalize(value)
    return nil if value.nil?

    # Mehr als ein Komma: Wo die Grenze zwischen Nach- und Vorname urspruenglich
    # lag, ist nicht mehr rekonstruierbar (die alte Fassung entfernte nur das
    # erste Komma je Eingabe). Eine Grenze zu raten hiesse, Namensteile zwischen
    # den Feldern zu verschieben. Deshalb nur aussen trimmen, die Struktur
    # bleibt unangetastet und der Fall wird eigens ausgewiesen.
    if value.count(',') > 1
      return keeper_strip(value)
    end

    last, first = value.split(',', 2)
    last = keeper_strip(last.to_s)
    first = keeper_strip(first.to_s)
    last = '' if last == 'undefined'
    first = '' if first == 'undefined'

    # Leer bleibt leer, und zwar als leere Zeichenkette statt als NULL: Das
    # Frontend schreibt es genauso (personName gibt '' zurueck), und knapp 1300
    # Zeilen je Spalte tragen bereits '' . Sie auf NULL zu ziehen waere eine
    # Bedeutungsaenderung ohne Nutzen, die 2600 defektfreie Zeilen anfasst.
    return '' if last.empty? && first.empty?
    # Ohne Vorname entfaellt das Trennzeichen. Mit Vorname bleibt es stehen,
    # auch wenn der Nachname fehlt: Aus ", Carolina" liest split(', ') den
    # Vornamen wieder als Vornamen, aus "Carolina" waere er ein Nachname.
    return last if first.empty?

    "#{last}, #{first}"
  end

  # Nur id und die eine Spalte laden. Ein find_each ueber ganze Game-Objekte
  # zieht die grossen JSONB-Spalten events und players mit und braucht fuer die
  # knapp 38.000 Zeilen je Spalte ein Vielfaches der Zeit; in einer ersten
  # Fassung lief der Lauf damit in einen Timeout.
  def keeper_each_value(col, &block)
    Game.where.not(col => nil).in_batches(of: 5_000) do |batch|
      batch.pluck(:id, col).each(&block)
    end
  end

  desc 'Bestandsaufnahme der Schriftfuehrer- und Zeitnehmer-Namen (nur lesend).'
  task report: :environment do
    keeper_columns.each do |col|
      total = Game.where.not(col => nil).count
      changes = 0
      ambiguous = 0
      samples = []

      keeper_each_value(col) do |_id, before|
        after = keeper_normalize(before)
        next if before == after

        changes += 1
        ambiguous += 1 if before.to_s.count(',') > 1
        samples << "    #{before.inspect} -> #{after.inspect}" if samples.size < 8
      end

      puts "#{col}: #{total} gesetzt, #{changes} wuerden sich aendern " \
           "(davon #{ambiguous} mit mehreren Kommata, dort wird nur getrimmt)"
      puts samples
    end
  end

  desc 'Raeumt "undefined" und ueberzaehlige Leerzeichen aus den Keeper-Namen. DRY_RUN=false zum Ausfuehren.'
  task cleanup: :environment do
    dry = keeper_dry_run?
    puts dry ? '=== DRY RUN, es wird nichts geschrieben (DRY_RUN=false zum Ausfuehren) ===' : '=== SCHREIBLAUF ==='

    keeper_columns.each do |col|
      changed = 0
      cleared = 0
      ambiguous = 0

      keeper_each_value(col) do |id, before|
        after = keeper_normalize(before)
        next if before == after

        changed += 1
        cleared += 1 if after.to_s.empty?
        ambiguous += 1 if before.to_s.count(',') > 1
        puts "  Spiel #{id}: #{before.inspect} -> #{after.inspect}"
        # update_all auf der einzelnen Zeile: keine Validierungen und Callbacks
        # auf Altdatensaetzen, und updated_at der Spiele bleibt unberuehrt.
        Game.where(id: id).update_all(col => after) unless dry
      end

      puts "#{col}: #{changed} geaendert (davon #{cleared} geleert, " \
           "#{ambiguous} mit mehreren Kommata nur getrimmt)"
    end

    puts 'Nichts geschrieben (Dry Run).' if dry
  end
end
