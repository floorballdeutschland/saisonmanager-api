# lib/tasks/fix_merge_ablage.rake
#
# Holt die Profile aus den Ablage-Vereinen zurueck, in denen eine Zusammenlegung sie
# haengen gelassen hat, und oeffnet ihren belegten Verein wieder.
#
# Ursache: Vor `Player#merge_into!` war der Transfer in einen Sammelverein ("Ablage
# Doppelung", "ZZ-Ablage", "zz_not in use" ...) der Behelf, um ein doppelt angelegtes Profil
# aus dem Weg zu raeumen. Die Zusammenlegung nahm diese Zugehoerigkeit wie jede andere mit
# auf das verbleibende Profil und drehte damit die Aussage um: Das echte Profil stand als
# Mitglied der Ablage da, sein Verein sah es nicht mehr in der eigenen Spielerliste, und
# lizenzieren oder transferieren liess es sich von dort nicht. Der Code-Fix dagegen ist
# api#566; dieser Lauf raeumt auf, was bis dahin entstanden ist.
#
# ZUERST api#566 ausliefern, dann diesen Lauf. Andernfalls kann eine Zusammenlegung den
# gerade geoeffneten Verein sofort wieder schliessen: `_close_surplus_home_clubs` behielt
# bis api#566 den zuletzt begonnenen Eintrag, und das ist die Ablage.
#
# Warum eine Datei statt einer Regel im Code: Welcher Verein je Profil geoeffnet wird, ist
# einzeln belegt worden (Stand 27.08.2026, Liste in `Merge-Ablage-Belegliste-2026-08-27`).
# Drei Belegarten, die juengste gewinnt:
#
#   Zugehoerigkeit bis zum Parken   Die Zugehoerigkeit, die in derselben Sekunde geschlossen
#                                   wurde, in der der Ablage-Eintrag entstand. Sie belegt
#                                   nicht das Ende der Mitgliedschaft, sondern dass sie bis
#                                   zum Parken LIEF -- also den Verein zu diesem Zeitpunkt.
#   Zugehoerigkeit regulaer beendet Ein Enddatum, das NICHT auf den Parkzeitpunkt faellt.
#   Lizenz S<n>                     Der Verein der Mannschaft der juengsten Lizenz, die je
#                                   erteilt, beantragt oder wegen Transfer beendet war.
#                                   Bewusst nicht der aktuelle Status: Der Lauf vom
#                                   12.08.2026 hat alte Lizenzen auf ungueltig gesetzt.
#
# Bei Gleichstand (vor der Freigabe-Logik konnte ein Profil in mehreren Vereinen offen
# stehen, beim Parken wurden alle in derselben Sekunde geschlossen) gewinnt der Verein, der
# zusaetzlich eine Lizenz traegt. Bleibt es mehrdeutig, steht das Profil nicht in der Liste.
#
# NICHT in der Liste stehen:
#   - Die 13 Profile in "Ablage Ausland (IFF Trans)". Der Verein ist kein Behelf, sondern das
#     laufende Verfahren fuer einen Transfer ins Ausland; jedes dieser Profile traegt einen
#     Transfer-Datensatz dorthin und danach keine deutsche Lizenz mehr. Dort ist der Zustand
#     richtig.
#   - "Ablage Sperrung" (213). Widerspruch nach Art. 21 DSGVO: Diese Personen wollen nicht
#     mehr im Saisonmanager erscheinen und duerfen nie in einen echten Verein zurueck.
#   - 15 Faelle zur Handpruefung: 14 mehrdeutige (darunter vier mit Auslandsepisode in der
#     Historie, die das Transferverfahren betreffen) und Profil 2733, dessen belegter Verein
#     deaktiviert ist -- ihn zu oeffnen wuerde die Person in einen stillgelegten Verein
#     einbuchen. Keiner dieser Faelle ist in S17 oder S18 aktiv, sie blockieren also keine
#     Lizenzierung.
#
# Von 1239 Merge-Zielen betrifft das 59 Profile. Drei davon sind in S17 aktiv und damit die
# eigentlich dringenden: 4742 Ludemann, 4876 Brueckner (der gemeldete Fall) und 5463
# Rustemeier.
#
# Drei Aktionen je Zeile:
#   entfernen    Der Ablage-Eintrag ist eine KOPIE aus der Dublette (gleicher Verein UND
#                gleiches created_at). Er war nie Historie dieses Profils und wird entfernt.
#   schliessen   Der Eintrag ist eigene Historie des Profils und wird geschlossen.
#   nur_oeffnen  Das Profil hat gar keine offene Zugehoerigkeit.
#
# Dry-Run (Standard):
#   bundle exec rails players:fix_merge_ablage USER_ID=<id>
# Ausfuehren:
#   bundle exec rails players:fix_merge_ablage USER_ID=<id> DRY_RUN=false
# Andere Liste:
#   CSV=/pfad/zur/datei.csv

# Die offenen Heimatvereine eines Profils, streng ueber ein leeres Enddatum. Eigene
# Methode, damit Vorbedingung und Nachbedingung des Laufs garantiert dasselbe pruefen.
def _offene_heimat_ids(player)
  offen = Array(player.clubs).select do |c|
    c.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(c['home_club']) && c['valid_until'].blank?
  end
  offen.map { |c| c['club_id'].to_i }.sort
end

namespace :players do
  desc 'Profile aus den Ablage-Vereinen zurueckholen (Liste aus CSV). DRY_RUN=false zum Ausfuehren.'
  task fix_merge_ablage: :environment do
    require 'csv'

    dry_run = ENV['DRY_RUN'] != 'false'
    user_id = ENV['USER_ID'].presence&.then { |v| Integer(v, exception: false) }
    pfad = ENV['CSV'].presence || Rails.root.join('lib/tasks/data/merge_ablage_2026_08_27.csv').to_s

    abort "Liste nicht gefunden: #{pfad}" unless File.exist?(pfad)
    # Ohne Benutzer keine Spur, wer den Eintrag geschlossen hat -- und genau diese Spur
    # braucht `unmerge_from!`, um eine Zugehoerigkeit spaeter wieder zuordnen zu koennen.
    abort 'USER_ID fehlt oder ist keine Zahl' if user_id.nil? && !dry_run

    # Marke an jedem Eintrag, den dieser Lauf angefasst hat. Sie macht die Aenderung im
    # Bestand auffindbar und einen Ruecklauf moeglich.
    quelle = 'merge_ablage_fix'

    zeilen = CSV.read(pfad, headers: true, col_sep: ';')
    puts "=== Profile aus den Ablagen zurueckholen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Liste: #{pfad} (#{zeilen.size} Eintraege)"
    puts

    repariert = 0
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

      aktion = zeile['aktion'].to_s
      # club_id durchgehend ueber to_i: Im Bestand steht sie teils als String, siehe
      # players:close_surplus_home_clubs. Ohne die Umwandlung vergleicht der Soll-Ist-Test
      # "129" gegen 129 und der Lauf meldete jede Zeile als abweichend.
      ablage = zeile['ablage'].presence&.to_i
      oeffnen = zeile['oeffnen'].to_i

      # Bewusst `valid_until.blank?` und NICHT `open_home_club_entries`: Dessen
      # Stichtagsvergleich ist tagesgenau, ein heute geschlossener Eintrag gilt dort bis
      # Mitternacht weiter als laufend. Ein zweiter Lauf am selben Tag saehe die gerade
      # geschlossene Ablage dann erneut als offen, faende den Zielverein aber schon
      # geoeffnet -- und legte ihn ein zweites Mal an.
      ist = _offene_heimat_ids(player)
      soll = ablage ? [ablage] : []

      if ist == [oeffnen]
        unveraendert += 1
        next
      end

      if ist != soll
        puts "##{player.id}: Lage weicht ab (erwartet #{soll.inspect}, vorgefunden #{ist.inspect}) -- uebersprungen"
        abweichend += 1
        next
      end

      ziel_name = Club.find_by(id: oeffnen)&.name || oeffnen
      ablage_name = ablage ? (Club.find_by(id: ablage)&.name || ablage) : '-'
      puts "##{player.id} #{player.first_name} #{player.last_name}: #{aktion} #{ablage_name}, " \
           "oeffnet #{ziel_name} (#{zeile['beleg']})"

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          eintraege = Array(player.clubs)

          case aktion
          when 'entfernen'
            eintraege = eintraege.reject do |c|
              c.is_a?(Hash) && c['club_id'].to_i == ablage && c['valid_until'].blank?
            end
          when 'schliessen'
            eintraege.each do |c|
              next unless c.is_a?(Hash) && c['club_id'].to_i == ablage && c['valid_until'].blank?

              c['valid_until'] = Time.now
              c['valid_set_by'] = user_id
            end
          when 'nur_oeffnen'
            nil
          else
            raise ArgumentError, "unbekannte Aktion #{aktion.inspect}"
          end

          # Den Zielverein oeffnen. Ein vorhandener geschlossener Eintrag wird
          # wiedereroeffnet und nicht durch einen neuen ersetzt: Sein `created_at` traegt
          # den Beginn der Mitgliedschaft, und `Player#home_club` wie `_merge_clubs` lesen
          # danach. Ein neuer Eintrag von heute wuerde behaupten, die Mitgliedschaft habe
          # heute begonnen. Gibt es mehrere, gewinnt der zuletzt beendete.
          kandidaten = eintraege.select do |c|
            c.is_a?(Hash) && c['club_id'].to_i == oeffnen && c['valid_until'].present? &&
              ActiveModel::Type::Boolean.new.cast(c['home_club'])
          end
          if (wieder = kandidaten.max_by { |c| c['valid_until'].to_s })
            wieder.delete('valid_until')
            wieder.delete('valid_set_by')
            wieder['source'] = quelle
          else
            eintraege << { 'club_id' => oeffnen, 'home_club' => true,
                           'created_at' => Time.now.iso8601, 'created_by' => user_id,
                           'source' => quelle }
          end

          player.clubs = eintraege
          player.updated_by = user_id
          player.save!(validate: false)

          # Nachbedingung: Genau der Zielverein steht offen, sonst zurueckrollen. Ohne sie
          # koennte der Lauf ein Profil ganz ohne Verein zuruecklassen -- unsichtbar in der
          # Vereinsliste, nicht lizenzierbar, nicht transferierbar.
          nachher = _offene_heimat_ids(player)
          if nachher != [oeffnen]
            raise "Nachbedingung verletzt: offene Heimat #{nachher.inspect}, erwartet #{[oeffnen].inspect}"
          end
        end
        repariert += 1
      rescue StandardError => e
        puts "  FEHLER: #{e.class}: #{e.message}"
        fehler += 1
      end
    end

    repariert = zeilen.size - unveraendert - abweichend - fehler if dry_run

    puts
    puts "#{repariert} Profil(e) #{dry_run ? 'zu reparieren' : 'repariert'}, " \
         "#{unveraendert} bereits in Ordnung, #{abweichend} mit abweichender Lage, #{fehler} Fehler."
    puts 'Dry-Run — nichts geschrieben. Mit DRY_RUN=false ausfuehren.' if dry_run

    # Nicht-null Exit-Code, damit ein Fehler nicht in einem gruen wirkenden Lauf untergeht.
    exit 1 if fehler.positive?
  end
end
