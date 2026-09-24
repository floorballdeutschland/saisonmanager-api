class GameDayMailer < ApplicationMailer
  # Informiert die SBK des Landesverbands, wenn ein:e Schiedsrichter:in einen
  # Spieltag über das Portal als nicht ordnungsgemäß durchgeführt meldet.
  def referee_checklist_veto(game_day, referee, answers, state_association)
    @game_day = game_day
    @referee = referee
    @answers = answers || []
    @failed_items = @answers.select { |a| a['answer'] == false }
    @league_name = game_day.league&.name
    @games, @games_matched = veto_games(game_day) do |game|
      assignment = game.referee_assignment
      assignment&.status == 'published' &&
        [assignment.referee1_id, assignment.referee2_id].include?(referee.id)
    end

    templated_mail(
      to: state_association.effective_sbk_email,
      subject: "Spieltag nicht ordnungsgemäß gemeldet – #{@league_name} am #{game_day.date}",
      placeholders: { league_name: @league_name, game_day_date: game_day.date, games: games_line(@games) }
    )
  end

  # Informiert den Ausrichter eines Spieltags, sobald für *alle* Spiele des
  # Spieltags die Schiedsrichter-Ansetzung veröffentlicht wurde. Eine einzige
  # zusammenfassende Mail je Spieltag (Idempotenz über GameDay#host_notified_at).
  def published_referees_to_host(game_day)
    @game_day = game_day
    @league_name = game_day.league&.name
    @games = game_day.games
                     .includes(:home_team, :guest_team, referee_assignment: %i[referee1 referee2 coach])
                     .sort_by { |g| g.start_time.to_s }

    templated_mail(
      to: game_day.club&.notification_emails,
      subject: "Schiedsrichteransetzungen – #{@league_name} am #{game_day.date}",
      default_reply_to: 'sr-ansetzungen@floorball.de',
      placeholders: { league_name: @league_name.to_s, game_day_date: game_day.date.to_s }
    )
  end

  # Informiert den Ausrichter, wenn die Schiedsrichter-/Coach-Besetzung eines
  # bereits veröffentlichten Spiels nachträglich geändert wurde (je Spiel).
  def updated_referees_to_host(game)
    @game = game
    @game_day = game.game_day
    @league_name = game.game_day.league&.name
    @assignment = game.referee_assignment

    templated_mail(
      to: game.game_day.club&.notification_emails,
      subject: "Schiedsrichteransetzung geändert – #{@league_name} am #{game.game_day.date}",
      default_reply_to: 'sr-ansetzungen@floorball.de',
      placeholders: { league_name: @league_name.to_s, game_day_date: game.game_day.date.to_s, game_time: game.start_time.to_s }
    )
  end

  # Informiert die SBK des Landesverbands, wenn eine Gastmannschaft einen
  # Spieltag über das Portal als nicht ordnungsgemäß durchgeführt meldet.
  def team_checklist_veto(game_day, team, answers, state_association)
    @game_day = game_day
    @team = team
    @answers = answers || []
    @failed_items = @answers.select { |a| a['answer'] == false }
    @league_name = game_day.league&.name
    @games, @games_matched = veto_games(game_day) { |game| [game.home_team_id, game.guest_team_id].include?(team.id) }

    templated_mail(
      to: state_association.effective_sbk_email,
      subject: "Spieltag nicht ordnungsgemäß gemeldet – #{@league_name} am #{game_day.date}",
      placeholders: { league_name: @league_name, game_day_date: game_day.date, games: games_line(@games) }
    )
  end

  # „Nr. 12, 14:30 Uhr: Heim vs. Gast“; fehlende Angaben fallen weg.
  def self.game_label(game)
    head = [game.game_number.presence && "Nr. #{game.game_number}",
            game.start_time.presence && "#{game.start_time} Uhr"].compact.join(', ')
    teams = "#{game.home_team_name} vs. #{game.guest_team_name}"
    head.present? ? "#{head}: #{teams}" : teams
  end

  private

  # Die Spiele, um die es in einer Spieltagsmeldung geht: die, an denen die
  # meldende Seite beteiligt war, samt der Angabe, ob das gelungen ist. Ohne
  # Treffer (z. B. Ansetzung inzwischen geändert) alle Spiele des Spieltags,
  # damit die SBK die Meldung trotzdem zuordnen kann; die View kennzeichnet sie
  # dann als solche.
  def veto_games(game_day, &involved)
    games = game_day.games
                    .includes(:home_team, :guest_team, :referee_assignment)
                    .sort_by { |g| [g.start_time.to_s, g.game_number.to_s.to_i] }
    involved_games = games.select(&involved)
    involved_games.any? ? [involved_games, true] : [games, false]
  end

  def games_line(games)
    games.map { |g| self.class.game_label(g) }.join('; ')
  end
end
