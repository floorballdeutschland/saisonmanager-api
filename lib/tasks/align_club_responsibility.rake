# lib/tasks/align_club_responsibility.rake
#
# Begleitet die Umstellung der Vereins-Zustaendigkeit auf den Landesverband
# (Club#main_game_operation_id).
#
# Vorher entschied ein zweites, am Verein gepflegtes Feld ueber die
# Zustaendigkeit: der Heimat-Eintrag in `clubs.game_operations_hash`. Es konnte
# dem Landesverband widersprechen, und weil das Bearbeiten-Formular es nicht
# zeigte, war der Widerspruch ueber die Oberflaeche nicht zu sehen. Aufgefallen
# ist das am ETV Hamburg, der mit Landesverband Hamburg in der Vereinsliste von
# Floorball Niedersachsen stand.
#
# BEIDE TASKS SIND AUF STAGING UND PRODUKTION GELAUFEN (20.08.2026).
#
# Sie bleiben stehen, weil sie die Entscheidung je Verein belegen und weil eine
# wiederhergestellte oder aus einem Altstand aufgesetzte Datenbank sie erneut
# braucht. Voreinstellung ist der Dry-Run, geschrieben wird nur mit DRY_RUN=false.
#
#   :fbh_under_flvsh
#             Haengt den Floorball Bund Hamburg unter den Floorballverband
#             Schleswig-Holstein und raeumt dabei auf, was daran haengt.
#             Beleg unten.
#
#   :fix_state_associations
#             Korrigiert die Landesverbands-Zuordnung der Vereine, bei denen das
#             Feld eine andere Frage beantwortet hat als die Zustaendigkeit.
#             Entscheidung je Verein aus einer Liste, nicht aus einer Regel:
#             lib/tasks/data/vereins_landesverbaende_2026_08_19.csv.
#
# In dieser Reihenfolge ausfuehren: Der zweite Task lehnt ein Ziel ohne
# zustaendigen Spielbetrieb ab, und fuer die Hamburger Vereine entsteht der erst
# durch den ersten.
#
# ENTFALLEN ist :responsibility_report. Er verglich den frueher in
# `clubs.game_operations_hash` gespeicherten Wert gegen den abgeleiteten und war
# das Tor nach dem Datenlauf. Mit dem Abbau der Spalte gibt es keinen zweiten
# Wert mehr, gegen den man vergleichen koennte -- und genau das war das Ziel. Sein
# Ergebnis auf Produktion vor dem Abbau: genau ein gewollter Wechsel (ETV
# Hamburg, 81), kein Verein ohne Zustaendigkeit, keine unerwartete Neuzuordnung.

namespace :clubs do
  # BELEG
  #
  # Bei 18 der 19 Vereine, deren Zustaendigkeit sich mit der Umstellung
  # verschieben wuerde, ist nicht der frueher gespeicherte Wert falsch, sondern
  # das Landesverbands-Feld: Es hat eine andere Frage beantwortet als die
  # Zustaendigkeit.
  #
  # Drei Muster, alle in der Liste einzeln belegt:
  #
  #   Auswahlteams   Bei den elf Trophy-Teams trug das Feld die *vertretene
  #                  Region*. Ausrichter des Wettbewerbs ist der Bundesverband,
  #                  und er pflegt die Auswahlen auch (Nutzer-Entscheidung vom
  #                  19.08.2026). Die Region steht weiterhin in `clubs.state`,
  #                  geht also nicht verloren.
  #   Kein Verband   Fuer Mecklenburg-Vorpommern gibt es keinen Landesverband,
  #                  fuer das Ausland auch nicht. Dort stand ein Platzhalter.
  #                  Zustaendig ist der Verband, in dessen Spielbetrieb die
  #                  Mannschaften antreten.
  #   Ablage         Ablage- und Veranstaltungs-Vereine haben keinen Sitz; ihre
  #                  LV-Werte waren zufaellig oder leer.
  #   Verbands-      Verein 220 traegt den Namen des Spielverbunds SBK Ost und
  #   eigene         gehoert ihm; sein LV-Wert stand auf dem Bundesverband.
  #
  # Nur Verein 66 (Partisan Connewitz) ist ein echter Fehler im Feld: Sitz ist
  # Leipzig-Connewitz, Ort und Bundesland standen auf Berlin.
  #
  # Warum eine Liste und keine Regel: Jede Zeile ist eine Einzelentscheidung mit
  # eigener Begruendung. Eine Regel wuerde sie verdecken und beim naechsten
  # Sonderfall stillschweigend das Falsche tun -- genau das war die Ursache des
  # Problems, das dieser PR behebt.
  #
  # `state` wird nur gesetzt, wo die Liste einen Wert nennt. Leer heisst
  # „unveraendert lassen", nicht „leeren": Bei den Auswahlteams traegt das Feld
  # die Region und muss stehenbleiben.
  #
  # Namen und Kuerzel in der Liste IMMER aus der Datenbank uebernehmen, nie aus
  # einer formatierten Konsolenausgabe. Beim ersten Anlauf auf .dev fielen vier
  # Zeilen durch die Namenspruefung, und alle vier gingen darauf zurueck: Zwei
  # Vereine heissen „Sued" statt „Süd" abgeschrieben, bei einem sah ein
  # fuehrendes Leerzeichen im Namen wie Spaltenausrichtung aus, und ein
  # Verbandskuerzel war geraten (FVBY statt FVB). Die Pruefung hat es abgefangen,
  # aber der Dry-Run ist dafuer die letzte Verteidigungslinie, nicht die erste.
  #
  # Dry-Run (Standard):
  #   bundle exec rails clubs:fix_state_associations
  # Ausfuehren:
  #   bundle exec rails clubs:fix_state_associations DRY_RUN=false
  # Andere Liste:
  #   CSV=/pfad/zur/datei.csv
  desc 'Korrigiert die Landesverbands-Zuordnung der Vereine aus einer Liste. DRY_RUN=false zum Ausfuehren.'
  task fix_state_associations: :environment do
    require 'csv'

    dry_run = ENV['DRY_RUN'] != 'false'
    pfad = ENV['CSV'].presence ||
           Rails.root.join('lib/tasks/data/vereins_landesverbaende_2026_08_19.csv').to_s
    abort "Liste nicht gefunden: #{pfad}" unless File.exist?(pfad)

    zeilen = CSV.read(pfad, headers: true, col_sep: ';')
    puts "=== Landesverbaende korrigieren #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Liste: #{pfad} (#{zeilen.size} Eintraege)\n\n"

    geaendert = 0
    unveraendert = 0
    fehler = 0

    ActiveRecord::Base.transaction do
      zeilen.each do |zeile|
        club = Club.find_by(id: zeile['club_id'])
        if club.nil?
          puts "  FEHLER: Verein #{zeile['club_id']} (#{zeile['name']}) nicht gefunden"
          fehler += 1
          next
        end

        # Der Name aus der Liste ist eine Sicherung, keine Anzeige: Steht unter
        # der ID inzwischen ein anderer Verein (Merge, Neuanlage), ist die
        # Entscheidung nicht mehr belegt und darf nicht angewendet werden.
        if zeile['name'].present? && club.name != zeile['name']
          puts "  FEHLER: Verein #{club.id} heisst '#{club.name}', erwartet '#{zeile['name']}' -- uebersprungen"
          fehler += 1
          next
        end

        ziel = StateAssociation.find_by(short_name: zeile['lv_kuerzel'])
        if ziel.nil?
          puts "  FEHLER: Landesverband '#{zeile['lv_kuerzel']}' nicht gefunden (Verein #{club.id})"
          fehler += 1
          next
        end

        # Ohne Spielbetrieb am Ziel waere der Verein danach herrenlos. Das ist
        # genau der Zustand, den die Umstellung beseitigt, und darf hier nicht
        # neu entstehen.
        ziel_go_id = GameOperation.id_by_state_association[StateAssociation.root_id(ziel.id)]
        if ziel_go_id.nil?
          puts "  FEHLER: '#{ziel.short_name}' hat keinen Spielbetrieb im Verbund (Verein #{club.id})"
          fehler += 1
          next
        end

        neuer_state = zeile['state'].presence
        state_aenderung = neuer_state.present? && club.state != neuer_state

        if club.state_association_id == ziel.id && !state_aenderung
          unveraendert += 1
          next
        end

        vorher_go = club.main_game_operation_id
        attrs = { state_association_id: ziel.id }
        attrs[:state] = neuer_state if state_aenderung

        puts "  #{club.id.to_s.ljust(5)} #{club.name.to_s.ljust(32)} " \
             "LV #{club.state_association_id.inspect} -> #{ziel.id} (#{ziel.short_name}), " \
             "zustaendig #{vorher_go.inspect} -> #{ziel_go_id}" \
             "#{state_aenderung ? ", Bundesland #{club.state.inspect} -> #{neuer_state}" : ''}"

        club.update!(attrs) unless dry_run
        geaendert += 1
      end

      # Die Liste ist ein Satz zusammengehoeriger Einzelentscheidungen, kein
      # Stapel unabhaengiger Aenderungen. Faellt eine Zeile durch (Verein
      # gemergt, umbenannt, Kuerzel vertippt), waere ein Teil-Commit der
      # gefaehrlichste Ausgang: 22 Vereine richtig, einer stillschweigend beim
      # falschen Verband, Exit-Status 0. Die Abbruchgruende sind kein `raise`,
      # sondern `next` -- ohne diese Klammer committete die Schleife.
      raise "#{fehler} Zeile(n) nicht anwendbar -- nichts geschrieben" if fehler.positive? && !dry_run
      raise ActiveRecord::Rollback if dry_run
    end

    puts
    puts "#{geaendert} Verein(e) #{dry_run ? 'zu aendern' : 'geaendert'}, " \
         "#{unveraendert} schon richtig, #{fehler} Fehler"
    puts 'Dry-Run -- nichts geschrieben. Mit DRY_RUN=false ausfuehren.' if dry_run
    unless dry_run
      puts 'Zustaendigkeit gegenpruefen: Club#main_game_operation_id je betroffenem Verein.'
    end
  end

  # BELEG
  #
  # Der Floorball Bund Hamburg (LV) hat keinen eigenen Spielbetrieb. Nach der
  # Umstellung waere fuer seine sechs Vereine niemand zustaendig: `permissions`
  # kennen nur `game_operation_id`, ohne Spielbetrieb laesst sich niemand fuer
  # Hamburg berechtigen.
  #
  # Fuenf der sechs Vereine (28, 91, 200, 276, 292) trugen ohnehin den
  # Spielbetrieb des FLV-SH, der sechste (81, ETV Hamburg) den von Niedersachsen,
  # obwohl seine Mannschaften in den Saisons 15-17 fast ausschliesslich in der
  # Regionalliga Nord (FLV-SH) und in den Bundesligen spielen. Mit dem
  # Elternverband bleiben die fuenf, wo sie waren, und der sechste kommt dorthin,
  # wo er spielt.
  #
  # Entscheidung des Nutzers vom 19.08.2026: "FBH richtet sich ganz nach SH".
  # Damit sind zwei Folgen ausdruecklich gewollt:
  #
  #   - Die Postfaecher (heute dreimal info@floorball.hamburg, am Morgen des
  #     19.08. von Hand eingetragen) werden geleert. Sie sollen auf die des
  #     FLV-SH zurueckfallen, was sie nur bei leerem eigenem Feld tun
  #     (StateAssociation#effective_sbk_email und Geschwister).
  #   - Expresslizenz und Kursergebnis-Freigabe des FLV-SH greifen fuer Hamburg
  #     mit. Beides folgt aus der Vererbungsrichtung und laesst sich am Kind
  #     nicht abschalten.
  #
  # Die Vereins-Freigabe von Hamburg an den FLV-SH wird damit redundant; sie
  # nimmt der Nutzer selbst zurueck. Der Task laesst sie stehen: Eine ueberzaehlige
  # Freigabe zeigt keinen Verein doppelt an (siehe den Test dazu in club_test.rb).
  #
  # Auflösung ueber die Kuerzel und nicht ueber feste IDs, aus demselben Grund wie
  # Club::FALLBACK_STATE_ASSOCIATION_SHORT_NAME: In db/seeds.rb liegen unter
  # denselben IDs andere Verbaende.
  #
  # Dry-Run (Standard):
  #   bundle exec rails clubs:fbh_under_flvsh
  # Ausfuehren:
  #   bundle exec rails clubs:fbh_under_flvsh DRY_RUN=false
  desc 'Haengt den Floorball Bund Hamburg unter den FLV-SH. DRY_RUN=false zum Ausfuehren.'
  task fbh_under_flvsh: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'

    fbh = StateAssociation.find_by(short_name: 'FBH')
    flvsh = StateAssociation.find_by(short_name: 'FLV-SH')

    abort 'FBH nicht gefunden (short_name FBH)' if fbh.nil?
    abort 'FLV-SH nicht gefunden (short_name FLV-SH)' if flvsh.nil?

    puts "=== FBH unter FLV-SH #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "#{fbh.name.strip} (#{fbh.id}) -> #{flvsh.name.strip} (#{flvsh.id})"
    puts "  parent_id:  #{fbh.parent_id.inspect} -> #{flvsh.id}"
    %i[sbk_email vsk_email rsk_email].each do |feld|
      puts "  #{"#{feld}:".ljust(11)} #{fbh[feld].inspect} -> nil (faellt auf den FLV-SH zurueck)"
    end

    # Ueber die Ableitung und nicht per find_by(state_association_id:): Bekommt der
    # FLV-SH selbst einmal einen Elternverband, entscheidet dessen Spielbetrieb,
    # und der direkte Nachschlag naehme den falschen (oder ginge leer aus, waehrend
    # die Zustaendigkeit sehr wohl existiert). fix_state_associations macht es
    # ebenso.
    ziel_go = GameOperation.by_id[GameOperation.id_by_state_association[StateAssociation.root_id(flvsh.id)]]
    abort "Fuer den FLV-SH (#{flvsh.id}) ist kein Spielbetrieb zustaendig -- sonst bleibt Hamburg herrenlos" if ziel_go.nil?

    betroffen = Club.where(state_association_id: fbh.id).order(:id)
    puts "\n  Vereine, deren Zustaendigkeit dadurch #{ziel_go.name} wird (#{betroffen.count}):"
    betroffen.each do |c|
      puts "    #{c.id.to_s.ljust(5)} #{c.name.to_s.ljust(30)} vorher #{c.main_game_operation_id.inspect}"
    end

    if dry_run
      puts "\nDRY RUN -- nichts geschrieben. Mit DRY_RUN=false ausfuehren."
      next
    end

    fbh.update!(parent: flvsh, sbk_email: nil, vsk_email: nil, rsk_email: nil)

    # Bewusst OHNE Rails.cache.delete('settings/init'): Der Cache-Store ist in
    # Produktion :memory_store, also je Prozess eigen. Ein Rake-Lauf hat seinen
    # eigenen Store und wuerde damit nichts leeren, was die laufenden
    # Puma-Arbeiter betrifft -- der Aufruf saehe nur nach einem Riegel aus. Die
    # Oberflaeche zeigt den alten Verbandsbaum deshalb bis zu 30 Minuten weiter,
    # sofern nicht ohnehin ein Deploy die Container neu startet. Dieselbe
    # Begruendung steht in app/models/current.rb.

    puts "\nGeschrieben. Zustaendig fuer Hamburg ist jetzt: " \
         "#{Club.where(state_association_id: fbh.id).first&.main_game_operation_id.inspect}"
  end
end
