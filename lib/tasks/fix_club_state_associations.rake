# lib/tasks/fix_club_state_associations.rake
#
# Einmalige Korrektur falscher Landesverbands-Zuordnungen an Vereinen
# (Stand 2026-08).
#
# Hintergrund: `clubs.state_association_id` gibt es erst seit Migration
# 20260414100001; gefüllt wurde die Spalte von Migration 20260427400001 aus dem
# Spielbetrieb des Vereins. Diese Ableitung fragt über
# `Club#main_game_operation_id` nach dem Heim-Spielbetrieb, nimmt dort aber den
# *ersten* als Heimat markierten Eintrag und prüft ihn per Ruby-Truthiness
# (`filter { |h| h['home_game_operation'] }`). Ein Alteintrag mit dem String
# `"false"` ist truthy – anders als beim strikten jsonb-`@>` in
# `GameOperation#home_clubs`. So konnte ein Gast-Spielbetrieb als Heimat gelten
# und dessen Landesverband am Verein landen: STV Sedelsberg spielte früher auch
# im Spielbetrieb Schleswig-Holstein und trägt seitdem FLV-SH.
#
# Maßgeblich ist deshalb nicht der Spielbetrieb, sondern das Bundesland des
# Vereins. `clubs:fix_state_associations` setzt den Landesverband auf den dafür
# zuständigen Verband und erledigt damit drei Fehlerbilder in einem Lauf:
#
#   - aus einem Gast-Spielbetrieb abgeleitete Landesverbände
#     (STV Sedelsberg: FLV-SH -> FVNB),
#   - Vereine an einem übergeordneten Landesverband. „SBK Ost" bietet das
#     Bearbeiten-Formular nicht an (dort stehen nur Blatt-Verbände; die API
#     erzwingt das nicht), diese Werte sind über die Oberfläche also nicht
#     reproduzierbar (Sachsen-Vereine: SBK Ost -> FVS). Ausgenommen bleiben die
#     Vereine aus Mecklenburg-Vorpommern: für ihr Bundesland gibt es keinen
#     Landesverband, sie bleiben am Dachverband und werden unten aufgelistet.
#   - Vereine am Landesverband ihres Spielbetriebs statt am eigenen
#     (Hamburger Vereine im SH-Spielbetrieb: FLV-SH -> FBH).
#
# Vereine mit ausländischer Anschrift haben keinen zuständigen Landesverband und
# gehören auf die Bundesebene (Hot Shots Innsbruck -> FVD). Ausland wird nicht
# geraten: eine nicht fünfstellige PLZ allein genügt nicht, weil eine deutsche
# PLZ aus dem 0er-Block ohne führende Null ebenfalls vierstellig ist
# (`"1067"` = Leipzig). Solche Vereine landen in der Prüfliste, verschoben wird
# nur, wen FOREIGN_CLUB_IDS ausdrücklich benennt.
#
# Bewusst NICHT betroffen, weil das Bundesland schon zum Landesverband passt:
# ETV Hamburg (FBH, spielt im Spielbetrieb Niedersachsen) und FC Rennsteig
# Avalanche (FVTH, spielt in SBK Ost).
#
# Absicherung: geändert wird nur, wenn die PLZ das hinterlegte Bundesland über
# `ApplicationRecord.postcodes` bestätigt. Alles andere wird übersprungen und am
# Ende aufgelistet, statt geraten zu werden.
#
# Default Dry-Run. Scharfschalten mit DRY_RUN=false.
# clubs:state_association_report gibt nur eine Übersicht aus (nie schreibend).

# Auflösung des zuständigen Landesverbands je Verein.
#
# Eigene Klasse statt Methoden im rake-namespace-Block: Letztere landen als
# private Methoden auf Object, und ihre Memoisierung (`@x ||=`) überlebt dann den
# Task-Lauf. Report- und Fix-Task im selben rake-Prozess – und mehrere
# Testläufe – sähen sonst veraltete Landesverbände.
class ClubStateAssociationResolver
  # Bundesland (ISO) -> zuständiger Landesverband (Kürzel). Mecklenburg-Vorpommern
  # fehlt bewusst: dort gibt es keinen Landesverband, solche Vereine werden
  # übersprungen statt geraten.
  STATE_TO_SA_SHORT = {
    'de-bw' => 'FVBW',
    'de-by' => 'FVB',
    'de-be' => 'FVBB',
    'de-bb' => 'FVBB',
    'de-hb' => 'FVNB', # Bremen wird vom FVNB betreut
    'de-hh' => 'FBH',
    'de-he' => 'FVH',
    'de-ni' => 'FVNB',
    'de-nw' => 'NWFV',
    'de-rp' => 'RLPSAAR',
    'de-sl' => 'RLPSAAR',
    'de-sn' => 'FVS',
    'de-st' => 'FVSA',
    'de-sh' => 'FLV-SH',
    'de-th' => 'FVTH'
  }.freeze

  # Dieselbe Quelle wie die Gruppierung in der Vereinsverwaltung: sonst könnte
  # der Task Vereine an einen Verband hängen, den die Anzeige nicht als
  # Bundesebene kennt.
  #
  # Als Methode und nicht als Konstante: der Klassenrumpf läuft beim Laden der
  # rake-Dateien, also vor `environment` – dort ist Club noch nicht autoloadbar
  # (`rake db:create` bricht sonst mit NameError ab).
  def self.national_sa_short
    ::Club::FALLBACK_STATE_ASSOCIATION_SHORT_NAME
  end

  def initialize(foreign_club_ids: [])
    @foreign_club_ids = foreign_club_ids.map(&:to_i)
    @sa_by_short_name = StateAssociation.all.index_by(&:short_name)
    @game_operations = GameOperation.includes(:state_association).index_by(&:id)
  end

  # Kürzel aus der Tabelle, zu denen es keinen Landesverband gibt. Ein
  # umbenanntes Kürzel würde sonst als „Bundesland ohne Landesverband"
  # durchgehen – die Meldung für Mecklenburg-Vorpommern.
  def missing_short_names
    (STATE_TO_SA_SHORT.values + [self.class.national_sa_short]).uniq - @sa_by_short_name.keys
  end

  # Kürzel, die mehrfach vorkommen. `index_by` behielte stillschweigend den
  # letzten Treffer, und auf state_associations.short_name liegt kein
  # Unique-Index – die Wahl entschiede dann über die Schreibvorgänge.
  def duplicate_short_names
    relevant = (STATE_TO_SA_SHORT.values + [self.class.national_sa_short]).uniq
    StateAssociation.where(short_name: relevant)
      .group(:short_name).having('count(*) > 1').count.keys
  end

  def national_state_association
    @sa_by_short_name[self.class.national_sa_short]
  end

  def home_state_association(club)
    @game_operations[club.main_game_operation_id]&.state_association
  end

  def expected_for_state(club)
    short = STATE_TO_SA_SHORT[club.state]
    short && @sa_by_short_name[short]
  end

  # Zielverband und Begründung:
  #   :ok               – Bundesland durch PLZ bestätigt, Zuordnung falsch.
  #   :foreign          – ausdrücklich als Auslandsverein benannt -> Bundesebene.
  #   :state_without_lv – Bundesland ohne eigenen Landesverband (MV).
  #   :no_state         – kein Bundesland hinterlegt.
  #   :unconfirmed      – PLZ bestätigt das hinterlegte Bundesland nicht. Dazu
  #                       gehören auch nicht fünfstellige PLZ: Ausland oder
  #                       fehlende führende Null lassen sich nicht unterscheiden.
  def resolve(club)
    return [national_state_association, :foreign] if @foreign_club_ids.include?(club.id)

    target = expected_for_state(club)
    return [nil, club.state.present? ? :state_without_lv : :no_state] if target.nil?
    return [target, :unconfirmed] unless state_confirmed_by_postcode?(club)

    [target, :ok]
  end

  # Deutsche Postleitzahlen sind fünfstellig.
  def german_postcode?(club)
    club.postcode.to_s.strip.match?(/\A\d{5}\z/)
  end

  # Bundesland laut den PLZ-Bereichen aus ApplicationRecord.postcodes.
  #
  # `cover?` schließt die Grenzen ein – Club#update_state vergleicht dort mit
  # < / > und lässt Randwerte fälschlich durchfallen.
  #
  # `dig` statt `fetch`: zwei Bereiche (Jungholz, Kleinwalsertal) tragen nur
  # `region: 'Außerhalb der BRD'` und gar keinen isocode. `fetch` würde dort mit
  # KeyError abbrechen – und zwar bei fünfstelligen PLZ, die diese Prüfung sonst
  # für deutsch hält.
  #
  # Bei mehrfach belegten PLZ gewinnt der erste Treffer der Tabelle. Für 21039
  # und 22145 steht Schleswig-Holstein vor Hamburg; solche Vereine landen
  # deshalb in der Prüfliste statt in der Korrektur.
  def postcode_state(club)
    value = club.postcode.to_s.strip.to_i
    Club.postcodes.find { |pc| (pc[:from]..pc[:till]).cover?(value) }&.dig(:isocode)
  end

  def state_confirmed_by_postcode?(club)
    german_postcode?(club) && postcode_state(club) == club.state
  end
end

namespace :clubs do
  def dry_run?
    ENV.fetch('DRY_RUN', 'true') != 'false'
  end

  # Nur die exakten Werte gelten. Ein Tippfehler (`DRY_RUN=False`, `0`, `no`)
  # bliebe sonst lautlos ein Dry-Run, und wer die Ausgabe nicht von oben liest,
  # hält den Lauf für erledigt.
  def check_dry_run_flag!
    value = ENV['DRY_RUN']
    return if value.nil? || %w[true false].include?(value)

    abort "DRY_RUN muss 'true' oder 'false' sein, war '#{value}'."
  end

  def label(state_association)
    return '—' if state_association.nil?

    "#{state_association.short_name} (#{state_association.id})"
  end

  def build_resolver
    resolver = ClubStateAssociationResolver.new(
      foreign_club_ids: ENV.fetch('FOREIGN_CLUB_IDS', '').split(',').map(&:strip).reject(&:empty?)
    )

    # Ohne die Landesverbände hinter den Kürzeln schreibt der Task nichts
    # Sinnvolles – lieber vorher abbrechen als 63 Vereine halb umhängen.
    missing = resolver.missing_short_names
    abort "Unbekannte Landesverbands-Kürzel: #{missing.join(', ')}" if missing.any?

    duplicates = resolver.duplicate_short_names
    abort "Mehrfach vergebene Kürzel: #{duplicates.join(', ')}" if duplicates.any?

    resolver
  end

  desc 'Setzt den Landesverband der Vereine auf den fuer ihr Bundesland zustaendigen Verband ' \
       '(Default Dry-Run, DRY_RUN=false zum Ausfuehren, FOREIGN_CLUB_IDS=1,2 fuer Auslandsvereine)'
  task fix_state_associations: :environment do
    check_dry_run_flag!
    resolver = build_resolver

    changes = []
    buckets = { unconfirmed: [], state_without_lv: [], no_state: [] }

    # find_each verwirft ein order und sortiert nach ID; für eine vergleichbare
    # Ausgabe deshalb erst sammeln, dann nach Namen sortieren.
    Club.includes(:state_association).find_each do |club|
      target, status = resolver.resolve(club)

      # Passt schon – unabhängig davon, wie gut das Bundesland belegt ist.
      next if target && club.state_association_id == target.id

      case status
      when :ok, :foreign then changes << [club, target, status]
      else buckets[status] << [club, target]
      end
    end

    changes.sort_by! { |club, _, _| club.name.to_s }

    puts dry_run? ? '[DRY RUN] Folgende Vereine wuerden korrigiert:' : 'Folgende Vereine werden korrigiert:'

    written = 0
    # Eine Transaktion: bricht ein Verein ab, bleibt keine halb korrigierte
    # Datenbank zurück.
    ActiveRecord::Base.transaction do
      changes.each do |club, target, status|
        note = status == :foreign ? ' [Ausland -> Bundesebene]' : ''
        # Vor dem Schreiben festhalten: danach ist der alte Wert weg.
        from = label(club.state_association)
        from_id = club.state_association_id

        unless dry_run?
          # update_columns statt update_column: updated_at mitziehen, sonst
          # sehen Caches und nachgelagerte Auswertungen die Änderung nicht.
          # Der Rückgabewert ist false, wenn die Zeile nicht mehr existiert.
          unless club.update_columns(state_association_id: target.id, updated_at: Time.current)
            raise ActiveRecord::Rollback, "Verein #{club.id} konnte nicht aktualisiert werden"
          end

          Rails.logger.info(
            "[clubs:fix_state_associations] Club #{club.id} (#{club.name}): " \
            "state_association_id #{from_id.inspect} -> #{target.id} (#{status})"
          )
        end

        # Erst nach dem Schreiben ausgeben, damit die Zeile kein Erfolg
        # behauptet, den es nicht gab.
        puts format('  %<id>-6s %<name>-34s %<state>-8s %<from>s -> %<to>s%<note>s',
                    id: club.id, name: club.name.to_s[0, 34], state: club.state.presence || '—',
                    from:, to: label(target), note:)
        written += 1
      end
    end

    puts "\n#{written} Verein(e) #{dry_run? ? 'zu korrigieren' : 'korrigiert'}."
    print_buckets(buckets, resolver)

    puts(dry_run? ? "\n*** DRY RUN – ES WURDE NICHTS GESCHRIEBEN. Erneut mit DRY_RUN=false. ***" : "\n*** #{written} Verein(e) GESCHRIEBEN. ***")
  end

  def print_buckets(buckets, resolver)
    if buckets[:unconfirmed].any?
      puts "\n#{buckets[:unconfirmed].size} Verein(e) uebersprungen, weil die PLZ das Bundesland nicht " \
           'bestaetigt. Ausland oder fehlende fuehrende Null? Bitte einzeln pruefen, ' \
           'Auslandsvereine per FOREIGN_CLUB_IDS nachziehen:'
      buckets[:unconfirmed].each do |club, target|
        puts format('  %<id>-6s %<name>-34s Land %<state>-8s PLZ %<plz>-8s laut PLZ %<derived>-8s ' \
                    'LV %<from>s, waere %<to>s',
                    id: club.id, name: club.name.to_s[0, 34], state: club.state.presence || '—',
                    plz: club.postcode.presence || '—', derived: resolver.postcode_state(club) || '—',
                    from: label(club.state_association), to: label(target))
      end
    end

    if buckets[:state_without_lv].any?
      puts "\n#{buckets[:state_without_lv].size} Verein(e) in einem Bundesland ohne eigenen Landesverband " \
           '(Mecklenburg-Vorpommern) – brauchen eine fachliche Entscheidung:'
      buckets[:state_without_lv].each do |club, _|
        puts format('  %<id>-6s %<name>-34s Land %<state>-8s LV %<from>s',
                    id: club.id, name: club.name.to_s[0, 34], state: club.state,
                    from: label(club.state_association))
      end
    end

    return if buckets[:no_state].empty?

    puts "\n#{buckets[:no_state].size} Verein(e) ohne hinterlegtes Bundesland – nicht zuordenbar " \
         '(ohne Landesverband in der Vereinsverwaltung unter dem Bundesverband gefuehrt):'
    buckets[:no_state].each do |club, _|
      puts format('  %<id>-6s %<name>-34s PLZ %<plz>-10s LV %<from>s',
                  id: club.id, name: club.name.to_s[0, 34],
                  plz: club.postcode.presence || '—', from: label(club.state_association))
    end
  end

  desc 'Zeigt Vereine, deren Landesverband vom zustaendigen Verband ihres Bundeslands abweicht (nur Uebersicht)'
  task state_association_report: :environment do
    resolver = build_resolver

    # Denselben Scope wie der Fix-Task, sonst zeigt die Vorschau etwas anderes
    # als der Lauf ändert – deaktivierte Vereine eingeschlossen.
    rows = Club.includes(:state_association).find_each.filter_map do |club|
      target, status = resolver.resolve(club)
      next if target && club.state_association_id == target.id

      [club, target, status]
    end.sort_by { |club, _, _| club.name.to_s }

    puts format('%<id>-6s %<name>-34s %<state>-6s %<plz>-8s %<from>-16s %<to>-16s %<status>-16s %<go>s',
                id: 'ID', name: 'Verein', state: 'Land', plz: 'PLZ', from: 'LV eingestellt',
                to: 'LV Bundesland', status: 'Status', go: 'LV Spielbetrieb')
    rows.each do |club, target, status|
      puts format('%<id>-6s %<name>-34s %<state>-6s %<plz>-8s %<from>-16s %<to>-16s %<status>-16s %<go>s',
                  id: club.id, name: club.name.to_s[0, 34], state: club.state.presence || '—',
                  plz: club.postcode.presence || '—', from: label(club.state_association),
                  to: label(target), status:, go: label(resolver.home_state_association(club)))
    end
    puts "\n#{rows.size} Verein(e) mit Abweichung (inkl. deaktivierter)."

    without_lv = Club.active.where(state_association_id: nil).count
    puts "#{without_lv} aktive(r) Verein(e) ohne Landesverband " \
         '(werden in der Vereinsverwaltung unter dem Bundesverband gefuehrt).'
  end
end
