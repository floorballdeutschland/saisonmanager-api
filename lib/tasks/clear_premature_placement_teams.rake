# lib/tasks/clear_premature_placement_teams.rake
#
# Einmal-Korrektur zu saisonmanager#515:
# Vor dem Fix (Commit 7e33c2b) hat Game.autofill_teams! Platzierungsspiele
# teils schon VOR Abschluss der Gruppenphase mit Teams gefüllt (z. B. DM-
# Halbfinals). Der Code-Fix verhindert künftige Fehl-Füllungen, setzt aber
# bereits falsch gesetzte home_team_id/guest_team_id NICHT zurück.
#
# Dieser Task setzt genau diese verfrühten Zuweisungen wieder auf NULL —
# als exakte Umkehrung des autofill-Guards: ein team_id wird nur dann
# geleert, wenn (a) eine Füllregel gesetzt ist, (b) das Spiel noch nicht
# begonnen hat und (c) die Füllbedingung aktuell NICHT erfüllt ist.
# Manuell (ohne Füllregel) gesetzte Teams bleiben unangetastet.
#
# SICHER PER DEFAULT: nur Report. Schreiben erst mit APPLY=1.
#   rake games:clear_premature_placement_teams            # Dry-Run (Report)
#   rake games:clear_premature_placement_teams APPLY=1    # tatsächlich leeren
#   rake games:clear_premature_placement_teams LEAGUE_ID=42 [APPLY=1]

namespace :games do
  desc 'saisonmanager#515: verfrüht gefüllte Platzierungsspiele zurücksetzen (Default Report, APPLY=1 schreibt)'
  task clear_premature_placement_teams: :environment do
    apply = ENV['APPLY'].present?
    league_id = ENV['LEAGUE_ID'].presence

    games = Game.not_started.has_autofill_condition
    games = games.where(game_day_id: GameDay.where(league_id:).select(:id)) if league_id

    cleared = 0
    affected_leagues = []

    games.find_each do |game|
      changed = false

      %w[home_team guest_team].each do |team|
        rule = game["#{team}_filling_rule"]
        param = game["#{team}_filling_parameter"]
        next if rule.blank? || param.blank?
        next if game["#{team}_id"].blank? # nichts zu leeren

        next if fill_condition_met?(game, rule, param)

        # Füllregel vorhanden, aber Bedingung (noch) nicht erfüllt → verfrüht
        puts "  Spiel ##{game.id} (Liga #{game.game_day&.league_id}, #{game.game_number}): " \
             "#{team}_id #{game["#{team}_id"]} → nil  [Regel #{rule}/#{param}]"
        game["#{team}_id"] = nil
        changed = true
        cleared += 1
      end

      next unless changed

      affected_leagues << game.game_day&.league_id
      game.save!(validate: false) if apply
    end

    affected_leagues.compact.uniq.each do |lid|
      next unless apply

      Rails.cache.delete("leagues/#{lid}/current_schedule")
      Rails.cache.delete("leagues/#{lid}/schedule")
    end

    summary = "#{cleared} verfrühte Team-Zuweisung(en) in #{affected_leagues.compact.uniq.size} Liga/Ligen"
    puts(apply ? "#{summary} zurückgesetzt." : "[REPORT — nichts geschrieben] #{summary} würden zurückgesetzt. " \
                                               'Mit APPLY=1 ausführen.')
  end

  # Spiegelt exakt die Füllbedingung aus Game.autofill_teams!:
  # game_-Regeln (Sieger/Verlierer eines Spiels) und place_-Regeln
  # (Tabellenplatz einer Gruppe). true = darf gefüllt sein.
  def fill_condition_met?(game, rule, param)
    if rule.start_with?('game_')
      reference_game = Game.find_by(id: param)
      return false unless reference_game

      return reference_game.send(rule.to_sym).present?
    end

    return false unless rule.start_with?('place_')

    group = rule.gsub('place_', 'group_')
    game_day_ids = GameDay.where(league_id: game.game_day.league_id).pluck(:id)
    group_games = Game.where(game_day_id: game_day_ids, group_identifier: group)
    return false if group_games.empty?

    closed_count = group_games.where(game_status: %w[match_record_closed finalized]).count
    return false if closed_count < group_games.count

    sub_table = game.league.grouped_table[group]&.fetch(:table, nil)
    place = param.to_i
    return false if sub_table.nil? || sub_table[place - 1].nil?

    # Exakte Parität zu autofill_teams!: gefüllt wird nur, wenn die
    # Tabellenzeile auch ein team_id trägt.
    sub_table[place - 1][:team_id].present?
  end
end
