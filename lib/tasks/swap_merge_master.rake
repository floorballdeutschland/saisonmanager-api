# lib/tasks/swap_merge_master.rake
#
# Dreht die Richtung eines Merges, ohne die Zusammenlegung selbst aufzuheben: Aus der
# Dublette wird der Master und umgekehrt.
#
# Wofuer: `players:merge_duplicates` fuehrt immer in die KLEINSTE ID zusammen (Kopf von
# merge_players.rake). Bei einem echten Duplikat entscheidet damit der Zufall der
# Anlagereihenfolge, welches Profil bestehen bleibt, und das ist regelmaessig nicht das, mit
# dem der Verein arbeitet. Der Schaden ist nicht nur kosmetisch: Der Merge schliesst die
# Zugehoerigkeiten der Dublette, und stand der laufende Heimatverein dort, gewinnt am Master
# ein alter Eintrag. Genau so gemeldet fuer Pavel Lubentsov am 04.09.2026 (3743 in 180
# gemergt am 08.07.2026, danach offener Heimatverein FBC Phoenix Leipzig statt SSC Leipzig).
#
# Abgrenzung zu `players:unmerge`: Dort werden zwei verschiedene Menschen getrennt, die die
# Dubletten-Heuristik zusammengezogen hat. Hier bleibt eine Person eine Person, nur die
# Richtung wechselt. `players:unmerge` ist fuer diesen Fall auch nicht benutzbar, seine
# beiden Vorbedingungen verweigern bei einem echten Duplikat (Lizenzen ohne id, Lizenzen in
# denselben Teams) -- Begruendung in `Player#swap_merge_master!`.
#
# Was der Lauf NICHT entscheidet: welches der beiden Profile das richtige ist. Das ist eine
# fachliche Frage (wer hat die laufende Zugehoerigkeit, welche ID kennt der Verein, welches
# Profil traegt die jungen Lizenzen), und sie gehoert vor den Aufruf.
#
# Dry-Run (Standard, laeuft echt und rollt zurueck):
#   bundle exec rails players:swap_merge_master NEW_MASTER_ID=3743 USER_ID=32
# Ausfuehren:
#   bundle exec rails players:swap_merge_master NEW_MASTER_ID=3743 USER_ID=32 DRY_RUN=false

namespace :players do
  desc 'Dreht die Richtung eines Merges (NEW_MASTER_ID=…, USER_ID=…). DRY_RUN=false zum Ausführen.'
  task swap_merge_master: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'

    # Integer() statt to_i: '3 743'.to_i ist 3 und '3743x'.to_i ist 3743. Eine verstuemmelte
    # ID kann auf ein ANDERES zusammengefuehrtes Profil treffen, und dann dreht der Lauf den
    # falschen Merge.
    new_master_id = Integer(ENV.fetch('NEW_MASTER_ID', nil).to_s.strip)
    user_id       = Integer(ENV.fetch('USER_ID', nil).to_s.strip)
    abort "User ##{user_id} nicht gefunden" unless User.exists?(id: user_id)

    neu = Player.find_by(id: new_master_id)
    abort "Profil ##{new_master_id} nicht gefunden" if neu.nil?
    abort "Profil ##{new_master_id} ist nicht zusammengeführt" if neu.merged_into_id.blank?

    alt = Player.find_by(id: neu.merged_into_id)
    abort "Alter Master ##{neu.merged_into_id} nicht gefunden" if alt.nil?

    geschwister = Player.where(merged_into_id: alt.id).where.not(id: neu.id).pluck(:id)

    puts "=== Merge-Richtung drehen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Neuer Master: ##{neu.id} #{neu.first_name} #{neu.last_name}, geb #{neu.birthdate}, " \
         "deaktiviert #{neu.deactivated_at} (#{neu.deactivation_reason})"
    puts "Alter Master: ##{alt.id} #{alt.first_name} #{alt.last_name}, geb #{alt.birthdate}"
    puts "Geschwister-Dubletten am alten Master: #{geschwister.presence&.join(', ') || 'keine'}"
    puts

    if neu.birthdate.to_s != alt.birthdate.to_s
      puts "ACHTUNG: Die Geburtsdaten weichen ab (#{neu.birthdate} gegen #{alt.birthdate})."
      puts 'Das ist das Muster eines FEHL-Merges, also zweier verschiedener Personen. Dann ist'
      puts 'nicht die Richtung falsch, sondern der Merge selbst — siehe players:unmerge.'
      puts
    end

    bilanz = nil
    begin
      ActiveRecord::Base.transaction do
        bilanz = neu.swap_merge_master!(user_id)
        raise ActiveRecord::Rollback if dry_run
      end
    rescue Player::UnmergeRefused => e
      abort "ABBRUCH (Vorbedingung nicht erfuellt, nichts geaendert): #{e.message}"
    end

    puts "Lizenz-Merge-Eintraege zurueckgenommen: #{bilanz[:licenses_self]}"
    puts "Zugehoerigkeiten am neuen Master geoeffnet: #{bilanz[:reopened_self]}"
    puts "Kopierte Zugehoerigkeiten am alten Master entfernt: #{bilanz[:clubs]}"
    puts "Spielreferenzen umgeschrieben: #{bilanz[:games]}"
    puts "Geschwister-Dubletten umgehaengt: #{bilanz[:repointed]}"

    if bilanz[:clubs_manual].present?
      puts
      puts 'VON HAND PRUEFEN — Zugehoerigkeiten ohne eindeutigen Beleg, nichts entfernt:'
      bilanz[:clubs_manual].each do |cid|
        puts cid.is_a?(Integer) ? "  Verein #{cid} #{Club.find_by(id: cid)&.name}" : "  #{cid}"
      end
    end

    if bilanz[:skipped].present?
      puts
      puts 'VON HAND PRUEFEN — diese Verknuepfungen blieben wegen Eindeutigkeits-Kollision am'
      puts 'alten Master stehen:'
      bilanz[:skipped].each { |eintrag| puts "  #{eintrag}" }
    end

    neu.reload
    puts
    puts "Neuer Master ##{neu.id}: #{Array(neu.licenses).size} Lizenzen, " \
         "#{Array(neu.clubs).size} Zugehoerigkeiten, Heimatverein #{neu.home_club(Date.current)&.name.inspect}, " \
         "#{Game.referencing_player(neu.id).count} Spiele"

    puts
    if dry_run
      puts 'DRY RUN — zurueckgerollt, nichts geaendert. Mit DRY_RUN=false ausfuehren.'
    else
      # Erst nach dem Commit: Rails.logger ist nicht transaktional, ein Log im Modell wuerde
      # auch jeden Probelauf als vollzogen protokollieren.
      Rails.logger.info(
        "players:swap_merge_master: ##{neu.id} ist neuer Master von ##{alt.id} " \
        "(User ##{user_id}): #{bilanz.inspect}"
      )
      puts 'Ausgefuehrt.'
    end
  end
end
