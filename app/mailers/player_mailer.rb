class PlayerMailer < ApplicationMailer
  def license_approved(player, team)
    @player = player
    @team = team
    @league = team.league
    # Setting.season_name statt current_season['name']: Steht unter der Saison ein
    # blanker String, liefert String#[]('name') still nil und die Mail trägt eine
    # leere Saison im Betreff; fehlt der Key ganz, gab es einen NoMethodError
    # hinter deliver_later, die Mail kam also gar nicht an und niemand erfuhr davon.
    season = Setting.season_name(Setting.current_season_id)
    subject = "Lizenz erteilt – #{team.name}"
    subject += " (#{@league.name})" if @league
    # Nur mit lesbarem Namen anhängen, sonst endete der Betreff auf " - ".
    subject += " - #{season}" if season.present?
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

    # Zweite Absicherung: League#express_license_possible? verlangt seit api#461
    # eine erreichbare Adresse, dieser Zweig ist über das Antragsformular also
    # nicht mehr erreichbar. Bleibt er trotzdem stehen, weil der Mailer auch direkt
    # aufgerufen werden kann — und er meldet jetzt, statt nur stumm zurückzukehren:
    # Vorher war dieser `return` die einzige Stelle, die den Zustand kannte, und
    # der Verein hatte die kostenpflichtige Eilbearbeitung bereits bestellt.
    if sbk_email.blank?
      if defined?(Sentry)
        Sentry.capture_message("Expresslizenz-Antrag ohne erreichbare SBK-Adresse " \
                               "(league=#{league&.id.inspect}, team=#{team&.id.inspect})")
      end
      return
    end

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
  # Die Formfrage (Hash mit 'name' oder blanker String) entscheidet
  # Setting.season_name an einer Stelle. Ohne lesbaren Namen bleibt die Zeile in
  # der Mail weg: Die laufende Nummer der Saison sagt Eltern nichts.
  def season_name(league)
    Setting.season_name(league&.season_id)
  end
end
