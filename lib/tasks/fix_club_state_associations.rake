# lib/tasks/fix_club_state_associations.rake
#
# Einmalige Korrektur falscher Landesverbands-Zuordnungen an Vereinen
# (Stand 2026-08).
#
# Hintergrund: `clubs.state_association_id` existiert erst seit Migration
# 20260414100001 und wurde per Backfill aus dem Spielbetrieb abgeleitet. Dabei
# wurde nicht der Heim-Spielbetrieb herangezogen, sondern ein *Gast*-Spielbetrieb
# des Vereins. Beispiel: STV Sedelsberg spielte im Altsystem zusätzlich im
# Spielbetrieb Schleswig-Holstein (GO 5) und bekam dadurch FLV-SH als
# Landesverband, obwohl der Verein zum FVNB gehört. Die Gast-Spielbetriebe sind
# inzwischen entfernt, die daraus abgeleiteten Landesverbände blieben stehen.
#
# Maßgeblich ist deshalb nicht der Spielbetrieb, sondern das Bundesland des
# Vereins: `clubs:fix_state_associations` setzt den Landesverband auf den für das
# Bundesland zuständigen Verband. Damit sind drei Fehlerbilder in einem Lauf
# erledigt:
#
#   - aus einem Gast-Spielbetrieb abgeleitete Landesverbände
#     (z. B. STV Sedelsberg: FLV-SH -> FVNB),
#   - Vereine an einem übergeordneten Landesverband. SBK Ost ist im
#     Bearbeiten-Formular gar nicht auswählbar (dort stehen nur Blatt-LVs),
#     diese Werte sind über die UI also nicht reproduzierbar
#     (z. B. Sachsen-Vereine: SBK Ost -> Floorballverband Sachsen),
#   - Vereine am Landesverband ihres Spielbetriebs statt am eigenen
#     (z. B. Hamburger Vereine im SH-Spielbetrieb: FLV-SH -> FBH).
#
# Ausländische Vereine (PLZ vorhanden, aber nicht fünfstellig) haben keinen
# zuständigen Landesverband und gehören auf die Bundesebene:
#
#   - Hot Shots Innsbruck (PLZ 6020, `state` fälschlich 'de-st'): -> FVD.
#
# Bewusst NICHT betroffen, weil das Bundesland schon zum Landesverband passt:
# ETV Hamburg (FBH, spielt im Spielbetrieb Niedersachsen) und FC Rennsteig
# Avalanche (FVTH, spielt in SBK Ost).
#
# Absicherung: bei deutschen Vereinen wird nur geändert, wenn die PLZ das
# hinterlegte Bundesland über ApplicationRecord.postcodes bestätigt. Alles andere
# wird übersprungen und am Ende aufgelistet, statt geraten zu werden.
#
# Der Task ist per DEFAULT Dry-Run. Scharfschalten mit DRY_RUN=false.
# clubs:state_association_report gibt nur eine Übersicht aus (nie schreibend).

namespace :clubs do
  # Bundesland (ISO) -> zuständiger Landesverband (short_name).
  # Mecklenburg-Vorpommern hat keinen eigenen Landesverband und ist bewusst
  # nicht enthalten – solche Vereine werden übersprungen, nicht geraten.
  # Absichtlich eine Methode statt einer Konstante: Konstanten in einem
  # rake-namespace-Block landen im Top-Level-Namespace.
  def state_to_sa_short
    {
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
  end

  def dry_run?
    ENV.fetch('DRY_RUN', 'true') != 'false'
  end

  def sa_by_short_name
    @sa_by_short_name ||= StateAssociation.all.index_by(&:short_name)
  end

  def game_operations_by_id
    @game_operations_by_id ||= GameOperation.includes(:state_association).index_by(&:id)
  end

  def home_state_association(club)
    game_operations_by_id[club.main_game_operation_id]&.state_association
  end

  def expected_sa_for_state(club)
    short = state_to_sa_short[club.state]
    short && sa_by_short_name[short]
  end

  # Deutsche Postleitzahlen sind fünfstellig. Die Prüfung hängt bewusst an der
  # Stellenzahl und nicht am Zahlenwert: ein österreichisches „6020" ergibt via
  # to_i denselben Wert wie das deutsche „06020" und würde über die
  # PLZ-Bereiche unten sonst als Sachsen-Anhalt durchgehen.
  def german_postcode?(club)
    club.postcode.to_s.strip.match?(/\A\d{5}\z/)
  end

  # Bundesland laut PLZ-Bereichen aus ApplicationRecord.postcodes. Grenzen hier
  # inklusive (`cover?`) – Club#update_state vergleicht dort mit < / > und lässt
  # Randwerte fälschlich durchfallen.
  def postcode_state(club)
    value = club.postcode.to_s.strip.to_i
    Club.postcodes.find { |pc| (pc[:from]..pc[:till]).cover?(value) }&.fetch(:isocode)
  end

  # Bestätigt das hinterlegte Bundesland über die PLZ.
  def state_confirmed_by_postcode?(club)
    german_postcode?(club) && postcode_state(club) == club.state
  end

  # Ausländische PLZ (vorhanden, aber nicht fünfstellig).
  def foreign_postcode?(club)
    club.postcode.present? && !german_postcode?(club)
  end

  # Bundesebene für Vereine ohne zuständigen Landesverband.
  def national_state_association
    sa_by_short_name['FVD']
  end

  # Zielverband samt Begründung:
  #   :foreign     – ausländischer Verein, gehört auf die Bundesebene (FVD).
  #                  Die PLZ ist hier selbst der Nachweis, deshalb keine weitere
  #                  Bestätigung. Ohne diesen Zweig würde Hot Shots Innsbruck
  #                  (PLZ 6020, `state` fälschlich 'de-st') nach Sachsen-Anhalt
  #                  wandern.
  #   :no_mapping  – kein Bundesland hinterlegt oder Bundesland ohne eigenen
  #                  Verband (Mecklenburg-Vorpommern): nicht raten.
  #   :unconfirmed – PLZ bestätigt das hinterlegte Bundesland nicht.
  #   :ok          – Bundesland durch PLZ bestätigt.
  def resolve_target(club)
    return [national_state_association, :foreign] if foreign_postcode?(club)

    target = expected_sa_for_state(club)
    return [nil, :no_mapping] if target.nil?
    return [target, :unconfirmed] unless state_confirmed_by_postcode?(club)

    [target, :ok]
  end

  def label(state_association)
    return '—' if state_association.nil?

    "#{state_association.short_name} (#{state_association.id})"
  end

  desc 'Setzt den Landesverband der Vereine auf den für ihr Bundesland zuständigen Verband, ' \
       'ausländische Vereine auf den FVD (Default Dry-Run, DRY_RUN=false zum Ausführen)'
  task fix_state_associations: :environment do
    changed = 0
    without_responsible_lv = []
    without_state = []
    unconfirmed = []

    puts dry_run? ? '[DRY RUN] Folgende Vereine würden korrigiert:' : 'Folgende Vereine werden korrigiert:'

    Club.includes(:state_association).order(:name).find_each do |club|
      target, status = resolve_target(club)

      # Passt schon – unabhängig davon, wie gut belegt das Bundesland ist.
      next if target && club.state_association_id == target.id

      case status
      when :no_mapping
        club.state.present? ? without_responsible_lv << club : without_state << club
        next
      when :unconfirmed
        unconfirmed << [club, target]
        next
      end

      from = club.state_association
      note = status == :foreign ? ' [Ausland -> Bundesebene]' : ''
      puts format('  %-6s %-34s %-8s %s -> %s%s',
                  club.id, club.name.to_s[0, 34], club.state.presence || '—',
                  label(from), label(target), note)

      unless dry_run?
        club.update_column(:state_association_id, target.id)
        Rails.logger.info(
          "[clubs:fix_state_associations] Club #{club.id} (#{club.name}): " \
          "state_association_id #{from&.id.inspect} -> #{target.id} (#{status})"
        )
      end

      changed += 1
    end

    puts "\n#{changed} Verein(e) #{dry_run? ? 'zu korrigieren' : 'korrigiert'}."

    if unconfirmed.any?
      puts "\n#{unconfirmed.size} Verein(e) übersprungen, weil die PLZ das Bundesland nicht bestätigt " \
           '(bitte einzeln prüfen):'
      unconfirmed.each do |club, target|
        puts format('  %-6s %-34s Bundesland %-8s PLZ %-8s laut PLZ %-8s LV %s, wäre %s',
                    club.id, club.name.to_s[0, 34], club.state.presence || '—',
                    club.postcode.presence || '—', postcode_state(club) || '—',
                    label(club.state_association), label(target))
      end
    end

    if without_responsible_lv.any?
      puts "\n#{without_responsible_lv.size} Verein(e) in einem Bundesland ohne eigenen Landesverband " \
           '(z. B. Mecklenburg-Vorpommern) – brauchen eine fachliche Entscheidung:'
      without_responsible_lv.each do |club|
        puts format('  %-6s %-34s Bundesland %-8s LV %s',
                    club.id, club.name.to_s[0, 34],
                    club.state, label(club.state_association))
      end
    end

    if without_state.any?
      puts "\n#{without_state.size} Verein(e) ohne hinterlegtes Bundesland – nicht zuordenbar " \
           '(in der Vereinsverwaltung unter dem FVD geführt, solange kein Landesverband gesetzt ist):'
      without_state.each do |club|
        puts format('  %-6s %-34s PLZ %-10s LV %s',
                    club.id, club.name.to_s[0, 34],
                    club.postcode.presence || '—', label(club.state_association))
      end
    end
  end

  # -- Übersicht (nie schreibend) --------------------------------------------

  desc 'Zeigt Vereine, deren Landesverband vom zuständigen Verband ihres Bundeslands abweicht (nur Übersicht)'
  task state_association_report: :environment do
    rows = Club.active.includes(:state_association).order(:name).filter_map do |club|
      expected = expected_sa_for_state(club)
      next if expected && club.state_association_id == expected.id

      [club, expected]
    end

    puts format('%-6s %-34s %-8s %-10s %-16s %-16s %s',
                'ID', 'Verein', 'Land', 'PLZ', 'LV eingestellt', 'LV Bundesland', 'LV Spielbetrieb')
    rows.each do |club, expected|
      puts format('%-6s %-34s %-8s %-10s %-16s %-16s %s',
                  club.id, club.name.to_s[0, 34], club.state.presence || '—',
                  club.postcode.presence || '—', label(club.state_association),
                  label(expected), label(home_state_association(club)))
    end
    puts "\n#{rows.size} aktive(r) Verein(e) mit Abweichung."

    without_lv = Club.active.where(state_association_id: nil).count
    puts "#{without_lv} aktive(r) Verein(e) ohne Landesverband " \
         '(werden in der Vereinsverwaltung unter dem FVD geführt).'
  end
end
