class PlayerMailer < ApplicationMailer
  def license_approved(player, team)
    @player = player
    @team = team
    @league = team.league
    season = Setting.current_season['name']
    subject = "Lizenz erteilt – #{team.name}"
    subject += " (#{@league.name})" if @league
    subject += " - #{season}"
    templated_mail(
      to: player.email,
      subject:,
      placeholders: { team_name: team.name, league_name: @league&.name, season: }
    )
  end

  def express_license_requested(player, team, league)
    @player = player
    @team = team
    @league = league
    # An die SBK des Spielbetriebs der Liga, nicht an die des Vereinsverbands:
    # Über den Antrag entscheidet der Verband, der die Liga betreibt.
    sbk_email = league&.state_association&.effective_sbk_email
    return if sbk_email.blank?

    templated_mail(
      to: sbk_email,
      subject: "Expresslizenz beantragt: #{player.first_name} #{player.last_name} (#{team.name})",
      placeholders: {
        player_name: "#{player.first_name} #{player.last_name}",
        team_name: team.name
      }
    )
  end

  # Datenschutz-Information an die gesetzliche Vertretung einer minderjährigen
  # Person (Art. 13 DSGVO), ausgelöst durch die Lizenzbeantragung des Vereins.
  # Die Adresse gibt der Verein im Antragsformular an; bis 1.81.0 wurde sie nur
  # an der Lizenz vermerkt, verschickt wurde nie etwas.
  #
  # Antworten gehören zur SBK des Spielbetriebs, der die Liga betreibt: Sie
  # entscheidet über den Antrag und ist für die Verarbeitung der Lizenzdaten
  # zuständig. Ohne hinterlegte Adresse bleibt es beim Absender-Default.
  def guardian_privacy_info(player, team, league, guardian_email)
    return if guardian_email.blank?

    @player = player
    @team = team
    @league = league
    @club = team&.club
    @season = season_name(league)
    # Fehlt der Link, nennt die Vorlage stattdessen den Verein als Bezugsquelle –
    # eine tote Adresse wäre für Eltern schlechter als keine.
    @info_url = Setting.info_link_url('minor_privacy_bundesliga')

    templated_mail(
      to: guardian_email,
      subject: "Datenschutzinformation zur Lizenzbeantragung – #{player.first_name} #{player.last_name}",
      default_reply_to: league&.state_association&.effective_sbk_email.presence,
      placeholders: {
        player_name: "#{player.first_name} #{player.last_name}",
        club_name: @club&.name,
        team_name: team&.name,
        league_name: league&.name,
        season: @season,
        info_url: @info_url
      }
    )
  end

  private

  # Saison der Liga, nicht die laufende: Ein Antrag kann eine Liga der kommenden
  # Saison betreffen, während noch die alte aktiv ist.
  #
  # Je nach Altbestand steht unter einer Saison ein Hash mit 'name' oder ein
  # blanker String (vgl. Setting.current_season_start_year); `dig` bräche beim
  # String mit TypeError ab, und hinter deliver_later fiele der Ausfall
  # niemandem auf. Ohne lesbaren Namen bleibt die Zeile in der Mail weg: Die
  # laufende Nummer der Saison sagt Eltern nichts.
  def season_name(league)
    return nil if league&.season_id.blank?

    entry = Setting.current.seasons[league.season_id.to_s]
    entry.is_a?(Hash) ? entry['name'].presence : entry.presence
  end
end
