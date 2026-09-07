# Stellt Playoff- und Playdown-Ligen im Bestand von `cup` auf `playoff` um.
#
# HINTERGRUND
#
# api#608 hat den Ligamodus `playoff` eingefuehrt, den Bestand aber bewusst
# nicht angefasst: „bereits angelegte Playoff-Ligen tragen weiterhin Pokal,
# solange sie nicht umgestellt werden". Genau das holt dieser Lauf nach.
#
# Solange sie `cup` tragen, gehoeren sie zur Wettbewerbsgruppe `pokal`
# (LeagueCompetition::GROUP_BY_MODUS) -- mit zwei Folgen:
#
#   * Eine Sperre im Ligaspielbetrieb gilt in den Playoffs NICHT, obwohl die
#     Playoffs die Fortsetzung derselben Liga sind. Die Vorbelegung des
#     Sperrformulars ist `liga` + `meisterschaft`; wer in der letzten Partie
#     der Hauptrunde gesperrt wird, laeuft in der ersten Playoff-Partie auf.
#     Das ist der Anlass fuer diesen Lauf.
#   * Die Buehne zeigt das Pokal-Bild: `overlay.js` bildet `league_type ==
#     "cup"` auf den Schluessel `pokal` ab. Ein Bundesliga-Playoff laeuft
#     damit im Erscheinungsbild des Pokals statt in dem seiner Liga.
#
# Was sich NICHT aendert: `knockout?` umfasst `cup` und `playoff`, der
# Turnierbaum bleibt also. Die Ligaklasse bleibt ebenfalls stehen, aus ihr
# leitet sich das Wettbewerbszeichen ab.
#
# ABLAUF
#
#   rake leagues:mark_playoffs                       # 1. Vorschau (Dry-Run)
#   DRY_RUN=false rake leagues:mark_playoffs         # 2. umstellen
#   DRY_RUN=false rake leagues:unmark_playoffs IDS=… # 3. notfalls zurueck
#
# Einschraenken laesst sich der Lauf mit SEASON (eine oder mehrere Saison-ids,
# kommagetrennt). Fuer die Sperrwirkung zaehlt die laufende Saison; die
# abgelaufenen sind Kosmetik und koennen warten.
#
# Die Ausgabe gehoert gesichert -- sie ist die einzige Aufzeichnung, welche
# Ligen der Lauf angefasst hat, und die Grundlage fuer `unmark_playoffs`:
#
#   DRY_RUN=false rake leagues:mark_playoffs | tee /tmp/playoffs-$(date +%F).log
#
# DIE ERKENNUNG
#
# Der Lauf raet nicht. Er wertet drei Merkmale aus und ruehrt alles andere
# nicht an, sondern listet es zum Nachsehen auf:
#
#   1. QUALIFIKATION -- die Liga ist Ziel einer `LeagueQualification` vom Typ
#      playoff, playdown oder relegation. Das ist keine Ableitung, sondern eine
#      gepflegte Beziehung: Jemand hat eingetragen, dass die Plaetze x bis y
#      dieser Hauptrunde hierher fuehren.
#   2. VORRUNDE -- die Liga traegt eine `league_id_preround`. Eine Liga, die
#      eine Vorrunde fortsetzt, ist kein eigener Wettbewerb.
#   3. NAME -- Playoff, Playdown, Meister-/Ab-/Aufstiegs-/Platzierungsrunde
#      oder Relegation im Namen.
#
# Der Name kann auch dagegen sprechen: Steht Pokal, Cup oder Trophy darin,
# bleibt die Liga `cup` -- es sei denn, Merkmal 1 greift. Eine gepflegte
# Qualifikation wiegt schwerer als eine Benennung, und „Pokal-Playoff" gibt es
# als Wortbildung durchaus.
def liga_zeile(league)
  format('  %<id>-7s Saison %<saison>-4s %<name>s',
         id: league.id, saison: league.season_id, name: league.name)
end

namespace :leagues do
  desc 'Stellt Playoff-/Playdown-Ligen von cup auf playoff um. DRY_RUN=false zum Ausführen, SEASON=17,18 grenzt ein.'
  task mark_playoffs: :environment do
    # Als lokale Werte und nicht als Konstanten: Konstanten in einem
    # rake-Namespace landen auf Object.
    qualification_types = %w[playoff playdown relegation].freeze
    playoff_name = /play-?off|play-?down|meisterrunde|abstiegsrunde|aufstiegsrunde|platzierungsrunde|relegation/i
    cup_name = /pokal|cup|trophy/i

    dry_run = ENV['DRY_RUN'] != 'false'
    seasons = ENV['SEASON'].to_s.split(',').map(&:strip).reject(&:blank?)

    candidates = League.where(league_modus: 'cup')
    # `season_id` ist eine Zeichenkette, kein Bereich und keine Zahl.
    candidates = candidates.where(season_id: seasons) if seasons.any?
    candidates = candidates.order(:season_id, :name).to_a

    qualified_ids = LeagueQualification
                    .where(qualification_type: qualification_types)
                    .where.not(target_league_id: nil)
                    .distinct.pluck(:target_league_id).to_set

    umstellen = []
    behalten  = []
    offen     = []

    candidates.each do |league|
      grund = if qualified_ids.include?(league.id)
                'Qualifikation'
              elsif league.name.to_s.match?(cup_name)
                nil
              elsif league.league_id_preround.present?
                'Vorrunde'
              elsif league.name.to_s.match?(playoff_name)
                'Name'
              end

      if grund
        umstellen << [league, grund]
      elsif league.name.to_s.match?(cup_name)
        behalten << league
      else
        offen << league
      end
    end

    puts "Kandidaten (league_modus = cup#{seasons.any? ? ", Saison #{seasons.join(', ')}" : ''}): #{candidates.size}"
    puts

    puts "UMSTELLEN auf playoff: #{umstellen.size}"
    umstellen.each do |league, grund|
      puts format('  %<id>-7s Saison %<saison>-4s %<grund>-12s %<name>s',
                  id: league.id, saison: league.season_id, grund:, name: league.name)
    end
    puts

    puts "BLEIBEN Pokal (Name spricht dagegen): #{behalten.size}"
    behalten.each { |l| puts liga_zeile(l) }
    puts

    puts "KEIN MERKMAL, unangetastet: #{offen.size}"
    offen.each { |l| puts liga_zeile(l) }
    puts

    if dry_run
      puts '[DRY RUN] Es wurde nichts geändert. Zum Ausführen: DRY_RUN=false'
      next
    end

    # `update_all` fasst `updated_at` nicht an und laeuft an den Validierungen
    # vorbei -- beides ist hier gewollt: Der Bestand enthaelt Ligen, die aus
    # anderen Gruenden nicht validieren wuerden (fehlende Pflichtfelder aus dem
    # Altsystem), und der Lauf soll daran nicht scheitern.
    ids = umstellen.map { |league, _| league.id }
    League.where(id: ids).update_all(league_modus: 'playoff') if ids.any?

    puts "Umgestellt: #{ids.size}"
    puts "Zurücknehmen mit: DRY_RUN=false rake leagues:unmark_playoffs IDS=#{ids.join(',')}" if ids.any?
  end

  desc 'Nimmt eine Umstellung zurück: setzt die genannten Ligen von playoff auf cup. DRY_RUN=false zum Ausführen.'
  task unmark_playoffs: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    ids = ENV['IDS'].to_s.split(',').map(&:strip).reject(&:blank?).map(&:to_i)

    if ids.empty?
      puts 'IDS fehlt. Aufruf: DRY_RUN=false rake leagues:unmark_playoffs IDS=1,2,3'
      next
    end

    # Nur was auch playoff traegt: Eine Liga, die inzwischen von Hand anders
    # eingestellt wurde, wird nicht ueberschrieben.
    betroffen = League.where(id: ids, league_modus: 'playoff').order(:id)
    betroffen.each { |l| puts liga_zeile(l) }
    puts "Zurückzunehmen: #{betroffen.count} von #{ids.size} genannten"

    if dry_run
      puts '[DRY RUN] Es wurde nichts geändert. Zum Ausführen: DRY_RUN=false'
      next
    end

    puts "Zurückgesetzt auf cup: #{betroffen.update_all(league_modus: 'cup')}"
  end
end
