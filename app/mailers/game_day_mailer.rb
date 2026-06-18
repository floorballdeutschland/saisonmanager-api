class GameDayMailer < ApplicationMailer
  # Informiert die SBK des Landesverbands, wenn ein:e Schiedsrichter:in einen
  # Spieltag über das Portal als nicht ordnungsgemäß durchgeführt meldet.
  def referee_checklist_veto(game_day, referee, answers, state_association)
    @game_day = game_day
    @referee = referee
    @answers = answers || []
    @failed_items = @answers.select { |a| a['answer'] == false }
    @league_name = game_day.league&.name

    templated_mail(
      to: state_association.sbk_email,
      subject: "Spieltag nicht ordnungsgemäß gemeldet – #{@league_name} am #{game_day.date}",
      placeholders: { league_name: @league_name, game_day_date: game_day.date }
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
      to: game_day.club&.contact_email,
      subject: "Schiedsrichteransetzungen – #{@league_name} am #{game_day.date}",
      default_reply_to: 'sr-ansetzungen@floorball.de',
      placeholders: { league_name: @league_name.to_s, game_day_date: game_day.date.to_s }
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

    templated_mail(
      to: state_association.sbk_email,
      subject: "Spieltag nicht ordnungsgemäß gemeldet – #{@league_name} am #{game_day.date}",
      placeholders: { league_name: @league_name, game_day_date: game_day.date }
    )
  end
end
