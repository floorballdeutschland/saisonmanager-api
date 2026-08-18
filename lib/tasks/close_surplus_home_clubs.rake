# lib/tasks/close_surplus_home_clubs.rake
#
# Schliesst je Profil den ueberzaehligen offenen Heimatverein, den ein Merge vor
# api#481 stehengelassen hat.
#
# Ursache: `Player#_merge_clubs` entdoppelte nur bei DEMSELBEN Verein. Zwei
# verschiedene offene Heimatvereine -- einer vom Master, einer von der Dublette --
# ueberlebten beide. Stand 18.08.2026 betraf das 239 der 1231 Merge-Ziele.
#
# Warum eine Datei statt einer Regel im Code: Welcher der beiden Vereine bleibt, ist
# je Fall belegt worden, nicht hergeleitet. Zwei Quellen:
#
#   Ablage-Regel  Steht dem Profil eine Ablage (ZZ-Ablage, Ablage Doppelung, Ablage,
#                 Ablage Ausland, Z_TSV not in use, zz_not in use, ZZZ neu, BW) und ein
#                 echter Verein offen, bleibt der echte. Die Ablage war der Behelf aus
#                 der Zeit vor der Merge-Funktion; jetzt, wo der Merge existiert, gehoert
#                 das Profil an seinen Verein -- der kann es dort selbst deaktivieren.
#                 "Ablage Sperrung" (213) ist bewusst NICHT dabei: Dort liegen Personen,
#                 die nicht mehr im Saisonmanager erscheinen wollten.
#   Altsystem     Bei zwei echten Vereinen entscheidet der Stand des alten Servers
#                 (saisonmanager-de, Daten bis 09.07.2026). Dort hatte jedes dieser
#                 Profile genau EINEN offenen Heimatverein -- die Doppelung ist erst
#                 durch den Merge entstanden.
#
# In 15 Zeilen ist der bleibende Verein selbst eine Ablage. Das sind durchweg Faelle, in
# denen BEIDE offenen Eintraege Ablagen sind -- kein Profil behaelt eine Ablage gegenueber
# einem echten Verein. Welche der beiden bleibt, entscheidet dort der Altsystem-Stand.
# Bewusst so belassen (Entscheidung vom 18.08.2026): Diese Profile liegen ohnehin
# ausschliesslich in Ablagen, ein echter Verein steht nicht zur Wahl.
#
# Nicht enthalten sind 21 Faelle mit einem Transfer nach dem 09.07.2026 oder einem
# gesetzten Enddatum. Ein heute vollzogener Wechsel sieht wegen des tagesgenauen
# Stichtagsvergleichs bis Mitternacht wie eine Doppelung aus und ist keine.
#
# Dry-Run (Standard):
#   bundle exec rails players:close_surplus_home_clubs
# Ausfuehren:
#   bundle exec rails players:close_surplus_home_clubs DRY_RUN=false
# Andere Liste:
#   CSV=/pfad/zur/datei.csv

namespace :players do
  desc 'Ueberzaehligen offenen Heimatverein je Profil schliessen (Liste aus CSV). DRY_RUN=false zum Ausfuehren.'
  task close_surplus_home_clubs: :environment do
    require 'csv'

    dry_run = ENV['DRY_RUN'] != 'false'
    pfad = ENV['CSV'].presence ||
           Rails.root.join('lib/tasks/data/doppelte_heimatvereine_2026_08_18.csv').to_s

    unless File.exist?(pfad)
      abort "Liste nicht gefunden: #{pfad}"
    end

    zeilen = CSV.read(pfad, headers: true, col_sep: ';')
    puts "=== Ueberzaehlige Heimatvereine schliessen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Liste: #{pfad} (#{zeilen.size} Eintraege)\n\n"

    geschlossen = 0
    unveraendert = 0
    abweichend = 0
    fehler = 0

    zeilen.each do |zeile|
      player = Player.find_by(id: zeile['player_id'])
      unless player
        puts "##{zeile['player_id']}: Profil nicht gefunden"
        fehler += 1
        next
      end

      behalten = zeile['behalten'].to_i
      # Komma als inneres Trennzeichen, NICHT Semikolon: Das ist der Spaltentrenner der
      # Datei selbst. Heute traegt jede Zeile genau eine zu schliessende ID, bei dreien
      # waere die Spalte sonst nur noch mit Anfuehrungszeichen eindeutig.
      schliessen = zeile['schliessen'].to_s.split(',').map(&:to_i)

      offen = player.open_home_club_entries

      # Der Bestand kann sich seit dem Erstellen der Liste geaendert haben. Nur handeln,
      # wenn genau die erwartete Lage vorliegt -- sonst lieber melden als raten.
      #
      # club_id durchgehend ueber to_i: Im Bestand steht sie teils als String
      # (lib/tasks/merge_clubs.rake:225 haelt das fest, und 17 Stellen in app/ vergleichen
      # defensiv mit to_i). Ohne die Umwandlung wirft schon das sort mit
      # "comparison of String with Integer failed" -- ausserhalb des rescue weiter unten,
      # der Lauf risse also mitten im Bestand ab.
      ist = offen.map { |c| c['club_id'].to_i }.sort
      soll = ([behalten] + schliessen).sort

      if offen.size < 2
        # Nicht stillschweigend als "in Ordnung" durchwinken: Bleibt genau ein Eintrag
        # offen, es ist aber der falsche, haengt das Profil weiter am falschen Verein und
        # niemand erfaehrt davon. Das ist ein realer Fall, seit
        # players:reopen_memberships_after_deactivation geschlossene Zugehoerigkeiten
        # wieder oeffnet.
        if offen.size == 1 && ist.first != behalten
          puts "##{player.id}: nur noch #{Club.find_by(id: ist.first)&.name} offen, erwartet war " \
               "#{Club.find_by(id: behalten)&.name} -- bitte pruefen"
          abweichend += 1
        else
          unveraendert += 1
        end
        next
      end

      if ist != soll
        puts "##{player.id}: Lage weicht ab (erwartet #{soll.inspect}, vorgefunden #{ist.inspect}) -- uebersprungen"
        abweichend += 1
        next
      end

      namen = schliessen.map { |cid| Club.find_by(id: cid)&.name || cid }
      puts "##{player.id} #{player.first_name} #{player.last_name}: " \
           "behaelt #{Club.find_by(id: behalten)&.name}, schliesst #{namen.join(', ')} (#{zeile['beleg']})"

      next if dry_run

      begin
        # Ueber `offen` schreiben, nicht ueber alle clubs: Sonst traefe der Filter auch ein
        # offenes ZWEITSPIELRECHT beim selben Verein und schloesse es mit. Der Lauf soll
        # ausschliesslich den ueberzaehligen HEIMATverein schliessen.
        betroffen = offen.select do |c|
          schliessen.include?(c['club_id'].to_i) && c['valid_until'].blank?
        end
        if betroffen.empty?
          # Schon geschlossen. Kann vorkommen, weil ein heute geschlossener Eintrag dem
          # tagesgenauen Leser bis Mitternacht weiter als offen gilt -- ein zweiter Lauf
          # am selben Tag saehe ihn sonst erneut und stempelte ihn neu.
          unveraendert += 1
          next
        end
        betroffen.each { |c| c['valid_until'] = Time.now }
        player.save!(validate: false)
        geschlossen += 1
      rescue StandardError => e
        puts "  FEHLER: #{e.class}: #{e.message}"
        fehler += 1
      end
    end

    geschlossen = zeilen.size - unveraendert - abweichend - fehler if dry_run

    puts
    puts "#{geschlossen} Profil(e) #{dry_run ? 'zu bereinigen' : 'bereinigt'}, " \
         "#{unveraendert} bereits in Ordnung, #{abweichend} mit abweichender Lage, #{fehler} Fehler."
    puts 'Dry-Run — nichts geschrieben. Mit DRY_RUN=false ausfuehren.' if dry_run
  end
end
