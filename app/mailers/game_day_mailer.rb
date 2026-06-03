class GameDayMailer < ApplicationMailer
  # Informiert die SBK des Landesverbands, wenn ein:e Schiedsrichter:in einen
  # Spieltag über das Portal als nicht ordnungsgemäß durchgeführt meldet.
  def referee_checklist_veto(game_day, referee, answers, state_association)
    @game_day = game_day
    @referee = referee
    @answers = answers || []
    @failed_items = @answers.select { |a| a['answer'] == false }
    @league_name = game_day.league&.name

    mail(
      to: state_association.sbk_email,
      subject: "Spieltag nicht ordnungsgemäß gemeldet – #{@league_name} am #{game_day.date}"
    )
  end
end
