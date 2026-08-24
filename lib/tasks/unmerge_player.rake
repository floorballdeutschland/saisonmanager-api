# lib/tasks/unmerge_player.rake
#
# Kehrt einen Fehl-Merge um: zwei verschiedene Personen, die der Dubletten-Lauf vom
# 08.07.2026 zusammengezogen hat.
#
# Wie es dazu kommt: Das Clustering matcht auch Geburtsdaten, die sich in genau einer
# Ziffer unterscheiden (Tippfehler-Annahme). Der Sicherungsmechanismus dagegen,
# `Player#_shares_game_with?`, greift nur bei gemeinsamer Aufstellung im SELBEN Spiel.
# Spielen die beiden in verschiedenen Ligen, gibt es kein gemeinsames Spiel und der Merge
# laeuft durch.
#
# Erkennungsmerkmal eines Fehl-Merges: abweichendes Geburtsdatum UND eine erteilte Lizenz
# in derselben Saison bei einem anderen Verein. Eine Person spielt nicht gleichzeitig in
# zwei Regionalligen verschiedener Landesteile.
#
# Belegter Fall (Meldung TV Lilienthal, 24.08.2026):
#   26679 Alexander Schmidt, geb 15.07.2015, TV Lilienthal
#     -> 24193 Alexander Schmidt, geb 12.07.2015, SC Potsdam
#   Beide waren in S16 und S17 parallel lizenziert, 26679 in der Regionalliga Nordwest
#   (Teams 6659, 7105, 7122), 24193 beim SC Potsdam.
#
# Zweiter Schritt, der die Zugehoerigkeit danach ganz entfernte: Der Merge nahm die offene
# Heimatmitgliedschaft mit auf den Master, der hatte danach zwei offene Heimatvereine, und
# `players:close_surplus_home_clubs` schloss am 19.08.2026 den Lilienthal-Eintrag
# (Zeile `24193;187;3;Altsystem`). Das braucht keinen eigenen Schritt: dieser Lauf entfernt
# den kopierten Eintrag ohnehin komplett vom Master.
#
# Was der Lauf NICHT kann, siehe `Player#unmerge_from!`: Transfers, Korrekturantraege,
# Sperren und Transferantraege hat der Merge per update_all verschoben, ohne Spur ihrer
# Herkunft. Sie werden aufgelistet, nicht angefasst.
#
# Danach faellig: Die wieder geoeffneten Lizenzen stehen auf ihrem Stand VOR dem Merge,
# bei abgelaufenen Saisons also auf "erteilt". Den Saisonwechsel traegt
#   bundle exec rails seasons:invalidate_stale_licenses ADMIN_USER_ID=<id>
# nach (idempotent, fasst nur APPROVED/REQUESTED an).
#
# Dry-Run (Standard, laeuft echt und rollt zurueck):
#   bundle exec rails players:unmerge MERGED_ID=26679 USER_ID=32
# Ausfuehren:
#   bundle exec rails players:unmerge MERGED_ID=26679 USER_ID=32 DRY_RUN=false

namespace :players do
  desc 'Kehrt einen Fehl-Merge um (MERGED_ID=…, USER_ID=…). DRY_RUN=false zum Ausfuehren.'
  task unmerge: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'

    merged_id = ENV['MERGED_ID'].to_i
    abort 'MERGED_ID nicht gesetzt' if merged_id.zero?
    user_id = ENV['USER_ID'].to_i
    abort 'USER_ID nicht gesetzt' if user_id.zero?
    abort "User ##{user_id} nicht gefunden" unless User.exists?(id: user_id)

    dublette = Player.find_by(id: merged_id)
    abort "Profil ##{merged_id} nicht gefunden" if dublette.nil?
    abort "Profil ##{merged_id} ist nicht zusammengeführt" if dublette.merged_into_id.blank?

    master = Player.find_by(id: dublette.merged_into_id)
    abort "Master ##{dublette.merged_into_id} nicht gefunden" if master.nil?

    puts "=== Merge umkehren #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Dublette: ##{dublette.id} #{dublette.first_name} #{dublette.last_name}, " \
         "geb #{dublette.birthdate}, deaktiviert #{dublette.deactivated_at} (#{dublette.deactivation_reason})"
    puts "Master:   ##{master.id} #{master.first_name} #{master.last_name}, geb #{master.birthdate}"

    if dublette.birthdate.to_s == master.birthdate.to_s
      puts 'HINWEIS: Beide tragen dasselbe Geburtsdatum. Das ist NICHT das Muster eines'
      puts '         Fehl-Merges — bitte vorher fachlich klaeren, ob die Umkehrung richtig ist.'
    end

    bilanz = nil
    begin
      ActiveRecord::Base.transaction do
        bilanz = dublette.unmerge_from!(user_id)
        raise ActiveRecord::Rollback if dry_run
      end
    rescue ArgumentError => e
      abort "ABBRUCH: #{e.message}"
    end

    puts
    puts "Spiele zurueckgeschrieben:   #{bilanz[:games]}"
    puts "Lizenzen vom Master geloest: #{bilanz[:licenses]}"
    puts "Zugehoerigkeiten entfernt:   #{bilanz[:clubs]}"
    puts "Lizenzdokumente zurueck:     #{bilanz[:documents]}"

    if bilanz[:manual].present?
      puts
      puts 'VON HAND PRUEFEN — diese Assoziationen liegen am Master und tragen keine Herkunft:'
      bilanz[:manual].each { |typ, ids| puts "  #{typ}: #{ids.join(', ')}" }
    end

    puts
    if dry_run
      puts 'DRY RUN — zurueckgerollt, nichts geaendert. Mit DRY_RUN=false ausfuehren.'
    else
      puts 'Ausgefuehrt. Jetzt seasons:invalidate_stale_licenses laufen lassen, damit die'
      puts 'wieder geoeffneten Lizenzen abgelaufener Saisons den Saisonwechsel-Status bekommen.'
    end
  end
end
