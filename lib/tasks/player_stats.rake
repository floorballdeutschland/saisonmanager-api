# lib/tasks/player_stats.rake
#
# Naechtlicher Lauf: schreibt das Spielerdaten-Aggregat neu, aus dem die Rangliste
# unter „Spielerdaten" liest (Verein und Landesverband, Issue #465). Gerechnet wird
# liga-weise aus den beendeten Spielen; je Liga wird geloescht und neu eingefuegt,
# damit auch etwas wieder verschwinden kann. Dazu entsteht der Schnappschuss des
# laufenden Heimatvereins, an dem der Schalter „nur aktuell gemeldete Spieler" haengt.
#
# Der Lauf ist wiederholbar. Ohne Einschraenkung ist er vollstaendig -- bewusst, denn
# Korrekturen an Altspielen laufen hier ueber update_column und ruehren updated_at
# nicht an; ein inkrementeller Lauf wuerde sie dauerhaft uebersehen.
#
# Aufruf (voll):          rake player_stats:refresh
# Nur eine Saison:        rake player_stats:refresh SEASON_ID=18
# Nur eine Liga:          rake player_stats:refresh LEAGUE_ID=1999
# Vorschau ohne Wirkung:  DRY_RUN=1 rake player_stats:refresh
#
# Fuer Cron (naechtlich):
#   15 1 * * * docker exec saisonmanager_rails_api bundle exec rake player_stats:refresh RAILS_ENV=production >> /var/log/player_stats.log 2>&1
#
# Hinweis zur Einschraenkung: SEASON_ID und LEAGUE_ID rechnen nur diesen Ausschnitt neu
# und lassen den Heimatvereins-Schnappschuss unberuehrt. Sie sind der schnelle Nachlauf
# am Tag, kein Ersatz fuer den naechtlichen Volllauf.

namespace :player_stats do
  desc 'Schreibt das Spielerdaten-Aggregat neu (optional SEASON_ID=, LEAGUE_ID=, DRY_RUN=1).'
  task refresh: :environment do
    # Boolean-Cast statt ENV['DRY_RUN'].present?: Sonst waere ausgerechnet
    # DRY_RUN=false ein Probelauf, weil die Zeichenkette da ist.
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch('DRY_RUN', nil)) || false
    season_id = ENV.fetch('SEASON_ID', nil)
    league_id = ENV.fetch('LEAGUE_ID', nil)

    umfang = if league_id.present?
               "Liga #{league_id}"
             elsif season_id.present?
               "Saison #{season_id}"
             else
               'alle Ligen'
             end
    puts "=== Spielerdaten neu berechnen (#{umfang})#{dry_run ? ' [DRY RUN]' : ''} ==="

    result = PlayerStats::Refresher.new(
      season_id:, league_id:, dry_run:,
      progress: ->(message) { puts message }
    ).run!

    puts
    puts "Ligen:            #{result[:leagues]}"
    puts "Zeilen:           #{result[:rows]}"
    puts "Profile:          #{result[:profiles]}" if result[:profiles].positive?
    puts "Verwaiste Zeilen: #{result[:orphans]}" if result[:orphans].positive?
    puts "Uebersprungene Spiele: #{result[:skipped_games]}" if result[:skipped_games].positive?
    puts "Dauer:            #{result[:seconds]} s"
    puts '[DRY RUN] Es wurde nichts geschrieben.' if dry_run
  end
end
