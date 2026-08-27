# lib/tasks/remove_merge_phantom_memberships.rake
#
# Entfernt Vereinszugehoerigkeiten, die eine Zusammenlegung von einer Fehlanlage auf das
# echte Profil kopiert hat und die eine Mitgliedschaft behaupten, die es nie gab.
#
# Ursache: Bis api#566 nahm `Player#_merge_clubs` jede Zugehoerigkeit der Dublette mit auf
# den Master. Bei einer Fehlanlage -- ein Verein findet das vorhandene Profil nicht und
# legt bei sich ein neues an -- ist die erste Zugehoerigkeit dieses Profils aber kein
# Mitgliedschaftsereignis, sondern die Anlage selbst. Auf dem echten Profil liest sie sich
# hinterher als kurze Mitgliedschaft bei einem Verein, dem die Person nie angehoert hat.
# Gemeldet am 27.08.2026 an Spieler 4876: acht Tage bei UHC Weissenfels, wo er nie
# lizenziert war und zu dem es lediglich eine Freigabe gab.
#
# Warum eine Datei statt einer Regel im Code: Das naheliegende Merkmal "Heimat-Eintrag der
# Dublette ohne Lizenz bei diesem Verein" trifft auf Produktion 221 der 650 geerbten
# Eintraege, also jeden dritten. Es trifft eben auch Jugendliche, die Zeit vor der
# Lizenzierung und jeden, der eingetreten und nie aufgestellt worden ist. Verengt auf
# "zusaetzlich in derselben Sekunde geschlossen, in der der Ablage-Eintrag der Dublette
# begann" bleiben fuenf Eintraege im ganzen Bestand uebrig -- zu wenig fuer eine Regel, und
# das Parken in eine Ablage ist ohnehin der alte Behelf, den es seit `merge_into!` nicht
# mehr gibt. Ein neuer Fall dieser Art kann also kaum noch entstehen.
#
# Die Liste enthaelt zwei Arten von Eintraegen, beide nachweislich Kopien aus der Dublette
# (gleicher Verein UND gleiches created_at) und beide falsch:
#
#   Phantom-Mitgliedschaft  Die Anlage der Dublette, die auf dem echten Profil eine
#                           Mitgliedschaft behauptet, die der uebrigen Historie
#                           widerspricht. 4876 war in diesen acht Tagen nicht bei
#                           Weissenfels; 11562 war bis zum 06.11.2024 beim Gettorfer TV und
#                           nicht ab dem 29.10. beim Barkelsbyer SV.
#   Offene Ablage           Der Parkplatz der Dublette, offen auf einem deaktivierten
#                           Profil stehengeblieben. `players:fix_merge_ablage` hat am
#                           27.08.2026 nur aktive Profile behandelt, diese drei blieben
#                           zurueck und stehen bis heute als Mitglied einer Ablage da.
#
# NICHT in der Liste stehen die Faelle, in denen der kopierte Eintrag denselben Verein
# nennt, dem die Person ohnehin angehoert (18210 und 24325). Sie sind ueberfluessig, aber
# nicht falsch, und etwas Ueberfluessiges zu loeschen bringt kein Recht in Ordnung.
#
# Ebenso wenig in der Liste stehen die sieben Profile, bei denen die zuletzt erteilte
# Lizenz einen anderen Verein nennt als den heute offenen. Sieben davon sind belegt richtig:
# Bei 4243, 7897, 10590 und 11677 wurde die eigene Zugehoerigkeit in derselben Sekunde
# geschlossen, in der die Zugehoerigkeit der Dublette begann -- das ist ein echter Wechsel,
# nur ueber zwei Profile hinweg aufgeschrieben, und die Lizenz ist schlicht aelter. 569
# traegt einen laufenden Auslandstransfer. Offen bleibt allein 1280 Hausik, wo beide
# Eintraege undatiert sind und nichts ausser einer Lizenz von 2013 den Ausschlag gibt; das
# entscheidet ein Mensch.
#
# Zuerst api#570 ausliefern, dann diesen Lauf. Sonst kann die naechste Zusammenlegung
# desselben Profils denselben Zustand wieder herstellen.
#
# Dry-Run (Standard):
#   bundle exec rails players:remove_merge_phantom_memberships USER_ID=<id>
# Ausfuehren:
#   bundle exec rails players:remove_merge_phantom_memberships USER_ID=<id> DRY_RUN=false
# Andere Liste:
#   CSV=/pfad/zur/datei.csv

# Die offenen Heimatvereine eines Profils, streng ueber ein leeres Enddatum. Eigene
# Methode, damit Vorbedingung und Nachbedingung des Laufs garantiert dasselbe pruefen.
#
# Bewusst nicht `open_home_club_entries`: Dessen Stichtagsvergleich ist tagesgenau, ein
# heute geschlossener Eintrag gilt dort bis Mitternacht weiter als laufend.
def _phantom_offene_heimat(player)
  offen = Array(player.clubs).select do |c|
    c.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(c['home_club']) && c['valid_until'].blank?
  end
  offen.map { |c| c['club_id'].to_i }.sort
end

# Die Eintraege, die eine Zeile meint.
#
# Verglichen wird ueber ein PRAEFIX von created_at und valid_until und nicht ueber den
# ganzen Wert: Die Zeitstempel liegen in JSONB in verschiedenen Schreibweisen vor, mit und
# ohne Bruchteile, mit unterschiedlichem UTC-Versatz. Ein byte-genauer Vergleich in einer
# von Hand gepflegten Liste waere eine Fehlerquelle ohne Gegenwert. Die Genauigkeit auf die
# Sekunde reicht: Es gibt keinen zweiten Eintrag desselben Vereins in derselben Sekunde,
# den die Zeile nicht ohnehin meint -- und wo doch, faengt es die Spalte `anzahl` ab.
def _phantom_treffer(player, club_id, von, bis)
  Array(player.clubs).select do |c|
    next false unless c.is_a?(Hash) && c['club_id'].to_i == club_id
    next false unless c['created_at'].to_s.start_with?(von)

    bis.blank? ? c['valid_until'].blank? : c['valid_until'].to_s.start_with?(bis)
  end
end

namespace :players do
  desc 'Phantom-Mitgliedschaften aus Zusammenlegungen entfernen (Liste aus CSV). DRY_RUN=false zum Ausfuehren.'
  task remove_merge_phantom_memberships: :environment do
    require 'csv'

    dry_run = ENV['DRY_RUN'] != 'false'
    user_id = ENV['USER_ID'].presence&.then { |v| Integer(v, exception: false) }
    pfad = ENV['CSV'].presence ||
           Rails.root.join('lib/tasks/data/merge_phantom_memberships_2026_08_27.csv').to_s

    abort "Liste nicht gefunden: #{pfad}" unless File.exist?(pfad)
    # Der Lauf schreibt `updated_by`; ohne Benutzer bliebe die Aenderung anonym.
    abort 'USER_ID fehlt oder ist keine Zahl' if user_id.nil? && !dry_run

    zeilen = CSV.read(pfad, headers: true, col_sep: ';')
    puts "=== Phantom-Mitgliedschaften entfernen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Liste: #{pfad} (#{zeilen.size} Eintraege)"
    puts

    entfernt = 0
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

      club_id = zeile['club'].to_i
      von = zeile['von'].to_s
      bis = zeile['bis'].to_s
      anzahl = zeile['anzahl'].to_i
      # Leere Spalte heisst "danach steht kein Heimatverein offen". Das ist bei einem
      # deaktivierten Profil der richtige Zustand und muss ausdruecklich dastehen koennen.
      soll_offen = zeile['soll_offen'].to_s.split(',').map { |v| v.strip.to_i }.sort

      treffer = _phantom_treffer(player, club_id, von, bis)
      ist_offen = _phantom_offene_heimat(player)

      # Kein Treffer und die Lage stimmt schon: Im LIVE-Lauf ist das die Idempotenz, der
      # Eintrag wurde bereits entfernt. Im Dry-Run kann es das nicht sein, dort hat noch
      # niemand etwas entfernt -- eine Zeile ohne Treffer ist dann ein Fehler in der Liste
      # (Verein, Sekunde oder Profil daneben) und muss auffallen, sonst geht sie im
      # Vorlauf als "in Ordnung" durch und der Live-Lauf tut stillschweigend nichts.
      if treffer.empty? && ist_offen == soll_offen
        if dry_run
          puts "##{player.id}: kein Eintrag zu dieser Zeile gefunden -- Liste pruefen"
          abweichend += 1
        else
          unveraendert += 1
        end
        next
      end

      # Beide Vorbedingungen zusammen: Die Zeile muss genau so viele Eintraege treffen, wie
      # sie ankuendigt, UND die Lage danach muss die angekuendigte sein. Trifft sie mehr,
      # ist die Liste zu unscharf; trifft sie weniger, hat sich der Bestand bewegt.
      erwartet_danach = (ist_offen - (treffer.any? { |c| c['valid_until'].blank? } ? [club_id] : [])).sort
      if treffer.size != anzahl || erwartet_danach != soll_offen
        puts "##{player.id}: Lage weicht ab (#{treffer.size} statt #{anzahl} Treffer, " \
             "offen danach waere #{erwartet_danach.inspect} statt #{soll_offen.inspect}) -- uebersprungen"
        abweichend += 1
        next
      end

      club = Club.find_by(id: club_id)&.name || club_id
      puts "##{player.id} #{player.first_name} #{player.last_name}: entfernt #{anzahl}x #{club} " \
           "(#{von}#{bis.present? ? " bis #{bis}" : ', offen'}) -- #{zeile['beleg']}"

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          # equal? und nicht Array-Differenz: Zwei Eintraege koennen als Hash gleich sein
          # (bei 11562 sind sie es), und `-` entfernte dann beide fuer einen Treffer.
          player.clubs = Array(player.clubs).reject { |c| treffer.any? { |t| t.equal?(c) } }
          player.updated_by = user_id
          player.save!(validate: false)

          nachher = _phantom_offene_heimat(player)
          raise "Nachbedingung verletzt: offen #{nachher.inspect}, erwartet #{soll_offen.inspect}" if nachher != soll_offen

          uebrig = _phantom_treffer(player, club_id, von, bis)
          raise "Nachbedingung verletzt: #{uebrig.size} Eintrag/Eintraege nicht entfernt" if uebrig.any?
        end
        entfernt += 1
      rescue StandardError => e
        puts "  FEHLER: #{e.class}: #{e.message}"
        fehler += 1
      end
    end

    entfernt = zeilen.size - unveraendert - abweichend - fehler if dry_run

    puts
    puts "#{entfernt} Profil(e) #{dry_run ? 'zu bereinigen' : 'bereinigt'}, " \
         "#{unveraendert} bereits in Ordnung, #{abweichend} mit abweichender Lage, #{fehler} Fehler."
    puts 'Dry-Run — nichts geschrieben. Mit DRY_RUN=false ausfuehren.' if dry_run

    # Nicht-null Exit-Code, damit ein Fehler nicht in einem gruen wirkenden Lauf untergeht.
    exit 1 if fehler.positive?
  end
end
