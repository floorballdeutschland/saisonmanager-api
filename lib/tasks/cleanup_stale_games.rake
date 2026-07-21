# lib/tasks/cleanup_stale_games.rake
#
# Einmalige Bereinigung von Altlasten im Spielbetrieb (Stand 2026-07):
#
#   1) cleanup:close_started_games   – vergangene, begonnene, aber nie formal
#      abgeschlossene Spiele schließen (setzt ended/game_ended + game_status).
#   2) cleanup:cancel_unstarted_games – vergangene, nie gestartete Spiele auf
#      notice_type='Canceled' setzen (öffentlich „Abgesagt").
#   3) cleanup:delete_empty_leagues  – Ligen ohne Teams UND Spiele löschen.
#
# Alle drei sind per DEFAULT Dry-Run. Scharfschalten mit DRY_RUN=false.
# cleanup:stale_report gibt nur eine Übersicht aus (nie schreibend).
#
# Hintergrund/Scope-Entscheidungen (mit Fachbereich abgestimmt):
#   - „Begonnen" = started=true. Beim Schließen wird ended/game_ended gesetzt,
#     damit vergangene Spiele öffentlich nicht dauerhaft als „Live" hängen.
#   - „Nie gestartet" wird nur bereinigt für aktuelle Saisons (nicht-legacy)
#     sowie die COVID-Legacy-Saisons 11 (2019/20) und 12 (2020/21). Andere
#     Legacy-Saisons (6–10, 13) bleiben ausgespart (mögliche fehlende Importe).
#   - Spiele mit angelegtem, aber nie gestartetem Bericht (record_created_at)
#     sowie reine Forfait-Spiele bleiben unangetastet.
#   - Leere Ligen der AKTIVEN Saison werden nicht gelöscht (in Aufbau); Ligen,
#     die von einer anderen Liga (Vorsaison/Vorrunde/direkter Vergleich) oder als
#     Ziel einer Qualifikation referenziert werden, werden übersprungen.

namespace :cleanup do
  # -- Helpers ---------------------------------------------------------------

  # game_status-Werte, die ein abgeschlossenes Spiel kennzeichnen.
  def closed_statuses
    %w[match_record_closed finalized]
  end

  # Legacy-Saisons, deren nie-gestartete Spiele als „Abgesagt" gelten (COVID).
  def cancel_legacy_season_ids
    [11, 12]
  end

  def parse_gd_date(str)
    return nil if str.blank?

    Date.parse(str.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Aktive Saison – wird bei allen drei Aktionen ausgenommen (in Aufbau bzw.
  # Ergebniserfassung noch im Gange). leagues.season_id ist eine Textspalte.
  def active_season_id
    Setting.current_season_id.to_s
  end

  # Kandidaten für „begonnen, nicht geschlossen": started=true, Status offen,
  # Spieltag-Datum in der Vergangenheit, nicht in der aktiven Saison. Datum wird
  # in Ruby geparst (Textspalte).
  def stale_started_games
    Game.where(started: true)
        .where('game_status IS NULL OR game_status NOT IN (?)', closed_statuses)
        .includes(game_day: :league)
        .select do |g|
      league = g.game_day&.league
      next false unless league && league.season_id.to_s != active_season_id

      (d = parse_gd_date(g.game_day&.date)) && d < Date.today
    end
  end

  # Kandidaten für „nie gestartet → Abgesagt": started=false, kein Ergebnis-,
  # Forfait- oder Berichtsansatz, kein bestehender Hinweis, Datum vergangen,
  # nicht in der aktiven Saison, und Saison im vereinbarten Scope.
  def cancelable_unstarted_games
    Game.where(started: false, forfait: 0, record_created_at: nil, notice_type: nil)
        .where('game_status IS NULL OR game_status = ?', 'pregame')
        .includes(game_day: :league)
        .select do |g|
      league = g.game_day&.league
      next false unless league && league.season_id.to_s != active_season_id

      d = parse_gd_date(g.game_day&.date)
      next false unless d && d < Date.today

      if g.legacy
        cancel_legacy_season_ids.include?(league.season_id.to_i)
      else
        true
      end
    end
  end

  # Ligen ohne Teams UND ohne Spiele, außerhalb der aktiven Saison.
  def empty_leagues
    team_counts = Team.group(:league_id).count
    game_counts = Game.joins(:game_day).group('game_days.league_id').count

    League.where.not(season_id: active_season_id).select do |lg|
      team_counts[lg.id].to_i.zero? && game_counts[lg.id].to_i.zero?
    end
  end

  # Wird die Liga von einer anderen Liga oder Qualifikation referenziert?
  # Gibt eine Liste von Gründen zurück (leer = löschbar).
  def league_reference_blockers(league)
    blockers = []
    refs = League.where.not(id: league.id).where(
      'league_id_preseason = :id OR league_id_preround = :id OR league_id_direct_encounters = :id',
      id: league.id
    ).pluck(:id)
    blockers << "referenziert von Ligen (Vorsaison/Vorrunde/dir. Vergleich): #{refs.join(', ')}" if refs.any?

    quali = LeagueQualification.where(target_league_id: league.id).pluck(:id)
    blockers << "Ziel von Qualifikationen: #{quali.join(', ')}" if quali.any?

    blockers
  end

  # -- 0) Report (read-only) -------------------------------------------------

  desc 'Übersicht über bereinigbare Altlasten (nur lesend)'
  task stale_report: :environment do
    started = stale_started_games
    unstarted = cancelable_unstarted_games
    empties = empty_leagues

    puts "=== Stale-Report (#{Date.today}) ==="
    puts "Begonnen, nicht geschlossen (schließbar): #{started.size}"
    puts "  davon legacy: #{started.count(&:legacy)}"
    puts "Nie gestartet im Scope (abzusagen): #{unstarted.size}"
    puts "  davon legacy (Saison #{cancel_legacy_season_ids.join('/')}): #{unstarted.count(&:legacy)}"
    puts "Leere Ligen (löschbar, ohne aktive Saison): #{empties.size}"
    blocked = empties.reject { |l| league_reference_blockers(l).empty? }
    puts "  davon referenziert (werden übersprungen): #{blocked.size}"
  end

  # -- 1) Spiele schließen ---------------------------------------------------

  desc 'Schließt vergangene, begonnene, aber nicht abgeschlossene Spiele. DRY_RUN=false zum Ausführen.'
  task close_started_games: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Begonnene Spiele schließen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    games = stale_started_games
    puts "Kandidaten: #{games.size}"
    affected_league_ids = []
    now = Time.now
    count = 0

    games.each do |g|
      affected_league_ids << g.game_day.league_id
      count += 1
      if count <= 20 || (count % 1000).zero?
        puts "  ##{g.id} (Liga #{g.game_day.league_id}, #{g.game_day.date}) " \
             "started=#{g.started} ended=#{g.ended} status=#{g.game_status.inspect}"
      end

      next if dry_run

      g.update_columns(
        ended: true,
        game_ended: true,
        game_status: 'match_record_closed',
        match_record_closed_at: g.match_record_closed_at || now
      )
    end

    puts "#{dry_run ? 'Würde schließen' : 'Geschlossen'}: #{count} Spiele in #{affected_league_ids.uniq.size} Ligen"
    flush_league_caches(affected_league_ids.uniq) unless dry_run
  end

  # -- 2) Spiele absagen -----------------------------------------------------

  desc 'Setzt vergangene, nie gestartete Spiele auf notice_type=Canceled. DRY_RUN=false zum Ausführen.'
  task cancel_unstarted_games: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Nie gestartete Spiele absagen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    games = cancelable_unstarted_games
    puts "Kandidaten: #{games.size} (legacy: #{games.count(&:legacy)})"
    affected_league_ids = []
    count = 0

    games.each do |g|
      affected_league_ids << g.game_day.league_id
      count += 1
      puts "  ##{g.id} (Liga #{g.game_day.league_id}, #{g.game_day.date}, s#{g.game_day.league.season_id})" if count <= 20

      next if dry_run

      g.update_columns(notice_type: 'Canceled')
    end

    puts "#{dry_run ? 'Würde absagen' : 'Abgesagt'}: #{count} Spiele in #{affected_league_ids.uniq.size} Ligen"
    flush_league_caches(affected_league_ids.uniq) unless dry_run
  end

  # -- 3) Leere Ligen löschen ------------------------------------------------

  desc 'Löscht Ligen ohne Teams und Spiele (außer aktive Saison, außer referenzierte). DRY_RUN=false zum Ausführen.'
  task delete_empty_leagues: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Leere Ligen löschen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    empties = empty_leagues
    puts "Leere Ligen (ohne aktive Saison): #{empties.size}"
    deleted = 0
    skipped = 0

    empties.sort_by { |l| [l.season_id.to_i, l.id] }.each do |lg|
      blockers = league_reference_blockers(lg)
      gd_ids = GameDay.where(league_id: lg.id).pluck(:id)

      if blockers.any?
        skipped += 1
        puts "  ÜBERSPRUNGEN ##{lg.id} s#{lg.season_id} #{lg.name.inspect}: #{blockers.join('; ')}"
        next
      end

      puts "  #{dry_run ? 'WÜRDE LÖSCHEN' : 'LÖSCHE'} ##{lg.id} s#{lg.season_id} #{lg.name.inspect} " \
           "(#{gd_ids.size} leere Spieltage)"
      next if dry_run

      ActiveRecord::Base.transaction do
        GameDay.where(id: gd_ids).destroy_all
        LeagueQualification.where(source_league_id: lg.id).delete_all
        lg.destroy!
      end
      deleted += 1
    end

    puts "#{dry_run ? 'Würde löschen' : 'Gelöscht'}: #{dry_run ? empties.size - skipped : deleted} Ligen, übersprungen: #{skipped}"
  end

  # Invalidiert die public-Caches der betroffenen Ligen, da update_columns die
  # after_commit-Callbacks (Game#flush_league_caches) umgeht. Löscht dieselben
  # Liga-Keys wie dort; die pro-Spieltag- und Player-Stats-Keys laufen per TTL
  # aus (einmalige Altlast-Bereinigung, kein Realtime-Pfad).
  def flush_league_caches(league_ids)
    league_ids.each do |lid|
      %w[schedule current_schedule table grouped_table scorer].each do |key|
        Rails.cache.delete("leagues/#{lid}/#{key}")
      end
    end
    puts "Caches invalidiert für #{league_ids.size} Ligen"
  end
end
