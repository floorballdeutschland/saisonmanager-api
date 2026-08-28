class ClubsController < ApplicationController
  include LicenseDocumentPresentation
  include LicenseAccessScope
  include SecretaryTokenAuthenticatable

  # `user_team_licenses` ist die einzige Aktion hier, die auch ohne Benutzerkonto
  # erreichbar sein muss: Der Kader-Dialog im Spielbericht läuft beim
  # Spielsekretariat auf einem Spielsekretariats-Link, und dort ist der Token die
  # Berechtigung. Ohne Login und ohne brauchbaren Token bleibt es bei 401.
  skip_before_action :authenticate_user, only: %i[user_team_licenses]
  before_action :authenticate_user_or_secretary_link, only: %i[user_team_licenses]

  def user_clubs_and_teams
    ph = current_user.permission_hash
    # Alle Rollen additiv auswerten statt per elsif-Kette nur die erste: wer
    # neben Admin/SBK auch VM oder TM ist, verlor sonst genau die Vereine, die
    # außerhalb des eigenen Spielbetriebs liegen.
    clubs = if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
              Club.all
            else
              collected = []

              if ph[:admin].present? || ph[:sbk].present?
                go_ids = []
                go_ids << ph[:admin] if ph[:admin].present?
                go_ids << ph[:sbk] if ph[:sbk].present?
                go_ids.flatten!

                collected += clubs_for_game_operations(go_ids)
              end

              collected += Club.where(id: ph[:vm]).to_a if ph[:vm].present?
              collected += Team.current_season.where(id: ph[:tm]).flat_map(&:all_clubs) if ph[:tm].present?

              collected.compact.uniq
            end

    # Vereine mit vorgeladenen Logos neu laden und alle aktuellen Teams in
    # einer Abfrage holen (statt current_teams je Verein) – beseitigt das
    # N+1 aus Logo-Attachments, Teams-Queries, Ligen/Spielbetrieben und
    # Logo-Fallback-Vereinen, das den Endpoint bei vielen Vereinen (Admin)
    # mehrere Sekunden gekostet hat.
    club_ids = clubs.to_a.map(&:id)
    clubs = Club.includes(logo_attachment: :blob).where(id: club_ids)
    teams_by_club = current_teams_by_club(club_ids)

    result = []

    clubs.each do |club|
      club_teams = teams_by_club.fetch(club.id, [])
      item = club.full_hash
      teams = club_teams.select { |team| may_list_team?(ph, club, team) }
      item[:teams] = teams.map(&:full_hash)
      result << item
    end

    render json: result
  end

  # Vereine, für die der/die Nutzer*in Vereinsmanager*in oder Teammanager*in
  # ist – und nur die. Andere Rollen bleiben hier ausdrücklich unberücksichtigt:
  # Das Portal „Meine Spieler*innen" ist die Vereinssicht auf den eigenen
  # Spielerbestand (Menüpunkt `menu_item_player_vm`, ebenfalls nur VM/TM), nicht
  # die Verbandssicht. Für die gibt es die Spielerverwaltung (`menu_item_player_admin`).
  #
  # Der Unterschied zu `user_clubs_and_teams` ist der Grund für diese zweite
  # Aktion: Dort sind alle Rollen additiv, wer also zusätzlich SBK ist, bekommt
  # alle Vereine des Spielbetriebs. Genau daran ist das Portal gescheitert – es
  # fragte für jeden dieser Vereine die Spielerliste ab, und die Vereine aus
  # fremden Landesverbänden antworteten (zu Recht) mit 403.
  def vm_clubs_and_teams
    ph = current_user.permission_hash
    unless ph[:vm].present? || ph[:tm].present?
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    vm_club_ids = ph[:vm].to_a
    tm_teams = ph[:tm].present? ? Team.current_season.where(id: ph[:tm]).to_a : []
    club_ids = (vm_club_ids + tm_teams.flat_map(&:all_club_ids)).uniq

    clubs = Club.includes(logo_attachment: :blob).where(id: club_ids).order(:name)
    teams_by_club = current_teams_by_club(club_ids)
    tm_team_ids = tm_teams.map(&:id)

    render json: clubs.map { |club|
      item = club.full_hash
      # Als VM alle Mannschaften des Vereins, als TM nur die eigenen.
      teams = teams_by_club.fetch(club.id, []).select do |team|
        vm_club_ids.include?(club.id) || tm_team_ids.include?(team.id)
      end
      item[:teams] = teams.map(&:full_hash)
      # Ob dieser Verein dem Konto gehört, also ob darin angelegt werden darf
      # (api#530). Die Vereinssicht hängt daran auch „Deaktivieren" und
      # „Reaktivieren": dieselben Rollen, nur bezieht die Prüfung dort den
      # Verein aus der Zugehörigkeit der Person statt aus dem Aufruf
      # (PlayersController#can_deactivate_player?). Aus derselben Quelle wie die
      # Prüfung beim Schreiben, damit das Portal „Meine Spieler*innen" nicht aus
      # zwei unterschiedlich gescopten Angaben zusammenrechnen muss:
      # `permissions[:vm]` im Browser kennt den
      # Spielbetrieb des Vereins nicht, `Club#user_permissions` schon, und ein
      # zwischenzeitlich geändertes Recht steht im localStorage des Browsers
      # noch alt. Vorbild: admin/clubs/role_assignable.
      item[:manage_players] = club.user_permissions(current_user).include?(:create_player)
      item
    }
  end

  # Kader und Lizenzstand einer Mannschaft. Zwei Wege hierher:
  #
  # (a) eingeloggt: Admin, SBK der Liga, VM/TM der beteiligten Vereine bekommen
  #     das vollständige Team-Lizenzwesen.
  # (b) per Spielsekretariats-Link, also ohne Benutzerkonto: nur die Kaderliste,
  #     und nur für Mannschaften, die an einem vom Link abgedeckten Spieltag
  #     spielen.
  #
  # (b) fehlte, und das Sekretariat bezahlte es teuer: Der Kader-Dialog im
  # Spielbericht ruft diesen Endpunkt, bekam 401, und der ErrorInterceptor im
  # Frontend meldete daraufhin ab. Der Link erlaubt das Aufstellen
  # (GamesController::SECRETARY_ACTIONS enthält add_player_to_lineup), nur an die
  # Liste der aufstellbaren Personen kam niemand, und wer es am Spieltag
  # versuchte, verlor seinen Zugang.
  def user_team_licenses
    team = Team.find(params[:id])
    leagues = team.leagues

    if current_user && user_may_read_team_licenses?(leagues)
      render json: team_licenses_hash(team)
    elsif secretary_token_permits_team?(team)
      render json: secretary_team_licenses_hash(team)
    else
      render json: { success: false }, status: :forbidden
    end
  end

  def admin_get_go_clubs
    if current_user
      league = if params[:callType] == 'l'
                 League.find(params[:id])
               else
                 team = Team.find(params[:id])
                 team&.league
               end

      game_operation = league&.game_operation
      if game_operation && game_operation&.user_permissions(current_user)&.include?(:index_clubs)
        # Heim-Vereine des Spielbetriebs statt aller Hash-Treffer: Gast-Einträge
        # waren Altlast aus dem Import 2010–2014 (siehe can_read_admin_club?).
        own_ids = game_operation.home_clubs.pluck(:id)
        # Freigaben hier bewusst nach `league.season_id` und nicht nach
        # current_season – die Liga gibt die Saison vor, die Auswahl gilt für
        # deren Spieltage.
        released_sa_ids = StateAssociationRelease
                          .where(recipient_game_operation_id: game_operation.id, season_id: league.season_id)
                          .pluck(:grantor_state_association_id)
        released_ids = released_sa_ids.any? ? Club.where(state_association_id: released_sa_ids).pluck(:id) : []
        # Vereine, die in DIESER Liga eine Mannschaft haben – der Ersatz für den
        # Gast-Eintrag, und genauer als er: Ein Gastverein muss als Ausrichter
        # wählbar bleiben, auch ohne Freigabe seines Landesverbands.
        # `league.teams` statt `Team.where(league_id:)`: In einem Pokalwettbewerb
        # hängen Mannschaften über `cup_leagues` und nicht über ihre league_id.
        # Ohne das fehlte deren Verein in der Auswahl und wäre als Ausrichter
        # eines Pokal-Spieltags nicht wählbar.
        league_club_ids = league.teams.flat_map(&:all_club_ids).uniq
        # Bundesweiter Zugriff (Admin oder SBK mit game_operation_id 0) sieht alle
        # aktiven Vereine – analog zum global_access-Zweig in
        # Club.admin_user_clubs. Ohne das war die Auswahl für einen frisch
        # angelegten Wettbewerb des Bundesverbands praktisch leer: Der
        # Bundesverband hat kaum eigene Heim-Vereine, und ohne Mannschaft in der
        # Liga greift auch league_club_ids nicht. Genau der Fall einer Mannschaft,
        # die ausschließlich den Pokal spielt und dort erst angelegt werden muss.
        ph = current_user.permission_hash
        global_access = ph[:admin].to_a.include?(0) || ph[:sbk].to_a.include?(0)
        scope = if global_access
                  Club.active
                else
                  Club.where(id: (own_ids + released_ids + league_club_ids).uniq)
                end
        # full_hash liest logo_url und logo_small_url, beide fassen die
        # ActiveStorage-Anlage an. Ohne Preload kostet das je Verein zwei
        # zusätzliche Abfragen – bei bundesweitem Zugriff über alle aktiven
        # Vereine. Gleiche Vorsorge wie in Club.admin_user_clubs.
        render json: scope.includes(logo_attachment: :blob).order(:name).map(&:full_hash)
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  # Schlanke Vereinsliste für Auswahl-/Anzeige-Zwecke in den Verwaltungs-Views
  # (Schiri-, User-, Spieler-, Spieltag-Verwaltung, Lizenzlisten). Für alle
  # Verwaltungsrollen inkl. VM/TM zugänglich, aber ohne contact_email und
  # interne Felder (public_hash). Reine Schiri-Logins haben keinen Zugriff.
  #
  # active_only grenzt auf nicht deaktivierte Vereine ein. Standard bleibt die
  # vollständige Liste, weil Bestandsdaten (alte Mitgliedschaften, Spieltage)
  # sonst nicht mehr benennbar wären. Gesetzt wird der Parameter von Masken, die
  # nichts anderes tun als zuweisen, etwa der Direktzuweisung.
  #
  # `deactivated` für die Masken, die beides aus einer Liste bedienen: Das
  # Spielerprofil, das Schiedsrichterprofil und die Spieltagsmaske weisen einen
  # Verein zu UND benennen den bereits gespeicherten. Mit `active_only` fiele
  # der Bestandswert aus der Liste und stünde ohne Namen da, ohne die Angabe
  # konnten sie umgekehrt nicht selbst filtern, weil public_hash den Zustand
  # nicht mitliefert (fe#318). Bewusst hier statt in Club#public_hash: Der
  # Zustand gehört in die Verwaltungsliste, nicht in die key-geschützten
  # öffentlichen Endpunkte, die denselben Hash verwenden.
  #
  # Die Auswahl ist damit die eine Hälfte; serverseitig weisen
  # PlayersController#add_additional_club und die Neuanlage einen deaktivierten
  # Verein seit api#521 ohnehin ab.
  def admin_club_all
    ph = current_user.permission_hash
    unless %i[admin sbk vm tm rsk ansetzer].any? { |role| ph[role].present? }
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    clubs = Club.includes(logo_attachment: :blob).order(:name)
    clubs = clubs.active if ActiveModel::Type::Boolean.new.cast(params[:active_only])
    render json: clubs.map { |club| club.public_hash.merge(deactivated: club.deactivated_at.present?) }
  end

  # Wie #admin_club_all, aber eingegrenzt auf die Vereine, für die der User
  # vereinsgebundene Rollen (VM/TM) vergeben darf – für das Vereins-Dropdown der
  # Benutzeranlage. Deckungsgleich mit der Prüfung in
  # Admin::UsersController#create (gemeinsame Quelle: Club.role_assignable_for).
  def admin_club_role_assignable
    ph = current_user.permission_hash
    unless %i[admin sbk vm].any? { |role| ph[role].present? }
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    clubs = Club.role_assignable_for(current_user).includes(logo_attachment: :blob)
    render json: clubs.map(&:public_hash)
  end

  def admin_club_index
    if current_user
      include_deactivated = ActiveModel::Type::Boolean.new.cast(params[:include_deactivated])
      result = Club.admin_user_clubs(current_user, include_deactivated:)

      render json: result
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_club_deactivate
    return render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized unless current_user

    club = Club.find_by(id: params[:id])
    return render json: { error: 'Nicht gefunden' }, status: :not_found unless club

    unless club.user_permissions(current_user).include?(:update_club)
      return render json: { error: 'Keine Berechtigung' }, status: :forbidden
    end

    # Die Zahl der beendeten Transferanträge/Freigaben gehört in die Antwort:
    # Die Deaktivierung hat damit eine Nebenwirkung, die der Aufrufer sonst
    # nirgends sieht (api#528).
    ended = club.deactivate!(current_user.id)
    render json: club.full_hash.merge(ended_transfer_requests: ended.size)
  end

  def admin_club_reactivate
    return render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized unless current_user

    club = Club.find_by(id: params[:id])
    return render json: { error: 'Nicht gefunden' }, status: :not_found unless club

    unless club.user_permissions(current_user).include?(:update_club)
      return render json: { error: 'Keine Berechtigung' }, status: :forbidden
    end

    club.reactivate!
    render json: club.full_hash
  end

  # Voller Vereinsdatensatz (inkl. contact_email) für die Vereinsverwaltung –
  # Admin/SBK des Spielbetriebs und der Vereinsmanager des Vereins selbst
  # (beide über :update_own_club) sowie LV-Rollen mit aktueller
  # Vereins-Freigabe (StateAssociationRelease, Lesezugriff wie in
  # Club.admin_user_clubs).
  def admin_club
    if current_user
      club = Club.find(params[:id])

      unless can_read_admin_club?(club)
        return render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

      # `edit_restricted` pro Verein und nicht als Benutzer-Berechtigung: Wer
      # eine Spielbetriebsrolle für einen Verband UND eine Vereinsrolle für
      # einen Verein aus einem anderen Verband hat, darf beim einen alles und
      # beim anderen nur die Stammdaten. Ein Flag am Benutzer kann das nicht
      # ausdrücken. Bewusst hier statt in Club#full_hash: Der Hash reist über
      # GameDay#full_hash durch jede Spieltags-Antwort, wo eine
      # benutzerbezogene Angabe nichts zu suchen hat.
      render json: club.full_hash.merge(edit_restricted: !full_club_access?(club))
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  # Vereinsmanager des Vereins samt aktueller Auswahl – Grundlage für die
  # Empfängerliste im Vereinsformular.
  #
  # Eigene Aktion statt weiterer Felder in Club#full_hash: Der volle
  # Vereins-Hash reist über GameDay#full_hash durch jede Spieltags-Antwort.
  # Namen und Adressen von Benutzern gehören dort nicht hinein.
  #
  # Engeres Gate als `can_read_admin_club?`: Die Liste enthält Namen und
  # E-Mail-Adressen von Personen und dient allein dazu, den Verteiler
  # einzustellen. Ein fremder Landesverband mit Vereins-Freigabe darf die
  # Stammdaten lesen, aber deshalb nicht die Kontaktdaten der Vereinsmanager
  # bekommen – das wäre eine Ausweitung der Freigabe, die niemand erteilt hat.
  def admin_club_managers
    return render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized unless current_user

    club = Club.find_by(id: params[:id])
    return render json: { error: 'Nicht gefunden' }, status: :not_found unless club

    unless club.user_permissions(current_user).include?(:update_own_club)
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    excluded = club.notify_excluded_ids
    managers = club.club_managers.sort_by { |user| user.fullname.strip.downcase }

    render json: {
      notify_user_ids: managers.map(&:id).reject { |id| excluded.include?(id) },
      managers: managers.map do |user|
        { id: user.id, name: user.fullname.strip.presence || user.user_name,
          user_name: user.user_name, email: user.email }
      end
    }
  end

  def admin_club_update
    if current_user
      # to_i: params[:id] ist nur bei einem JSON-Body eine Zahl. Als
      # Form-Parameter kommt der String "0" an, und String#zero? gibt es nicht –
      # die Aktion lief dann in einen NoMethodError. Ein fehlendes :id gilt
      # ebenfalls als Anlage (nil.to_i == 0).
      create_modus = params[:id].to_i.zero?

      # Die Anlage prüft die Berechtigung am Spielbetrieb (siehe create_club),
      # die Änderung am Verein selbst.
      if create_modus
        create_club
      elsif (club = Club.find(params[:id])).user_permissions(current_user).include?(:update_own_club)
        update_club(club)
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_upload_logo
    if current_user
      club = Club.find(params[:id])

      unless club.user_permissions(current_user).include?(:update_own_club)
        return render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

      unless params[:logo].present?
        return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity
      end

      if (error = logo_upload_error(params[:logo]))
        return render json: { message: error }, status: :unprocessable_entity
      end

      club.logo.attach(params[:logo])
      render json: { logo_url: club.logo_url, logo_small_url: club.logo_small_url }
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  private

  # Der Token wird gelesen, aber nicht erzwungen (`set_secretary_link_if_present`
  # statt `authenticate_with_secretary_token_or_user`): Der
  # SecretaryTokenInterceptor im Frontend hängt einen im sessionStorage liegenden
  # Token an JEDE Anfrage. Ein veralteter Token brächte einer angemeldeten Person
  # sonst einen 401 ein, obwohl ihre Sitzung gilt, und der ErrorInterceptor
  # meldet auf 401 ab. Der Login hat hier also Vorrang, der Token ist der
  # Ersatzweg.
  def authenticate_user_or_secretary_link
    set_secretary_link_if_present
    return if current_user || @secretary_link

    render json: { success: false,
                   message: 'Nicht angemeldet, und kein gültiger Spielsekretariats-Link.' },
           status: :unauthorized
  end

  def user_may_read_team_licenses?(leagues)
    ph = current_user.permission_hash

    # get playing clubs, including sg
    teams = leagues.map(&:teams).flatten.compact.uniq
    club_ids = teams.map(&:all_club_ids).flatten.compact.uniq
    # get hosting clubs
    all_club_ids = [club_ids, leagues.map { |l| l.game_days.map(&:club_id) }].flatten.compact.uniq

    # Rollen additiv: ein VM, der zugleich TM eines Teams außerhalb seiner
    # Vereine ist, wurde von der elsif-Kette sonst am TM-Zweig vorbeigeleitet.
    ph[:admin].present? || sbk_can_access_leagues?(ph, leagues) ||
      # vm: permission for one of those clubs?
      (ph[:vm].present? && ph[:vm].intersection(all_club_ids).present?) ||
      # tm: get clubs for league teams of given team, permission for one of those?
      (ph[:tm].present? && ph[:tm].intersection(teams.map(&:id)).present?)
  end

  # Der Link ist über Spieltage ausgestellt (eine Halle an einem Tag, ggf.
  # mehrere Ligen). Ein Kader gehört dazu, wenn die Mannschaft an einem dieser
  # Spieltage ein Spiel hat – dieselbe Grenze wie beim Spielbericht selbst
  # (secretary_token_permits_game?), nur von der Mannschaft aus gefragt.
  def secretary_token_permits_team?(team)
    game_day_ids = @secretary_link&.covered_game_day_ids
    return false if game_day_ids.blank?

    Game.where(game_day_id: game_day_ids)
        .where('home_team_id = :team_id OR guest_team_id = :team_id', team_id: team.id)
        .exists?
  end

  # Für das Sekretariat bewusst nur, was der Aufstellungsdialog liest: Name,
  # Geburtsdatum (Kennzeichnung Minderjähriger) und der Lizenzstatus, nach dem
  # der Dialog die Aufstellbaren filtert. Kein `Player#full_hash`, das trüge
  # E-Mail-Adresse, Vereinshistorie und Deaktivierungsgrund in eine Ansicht, die
  # ohne Benutzerkonto offensteht; und kein Lizenzwesen (Pflichtdokumente,
  # Rücknahme, Express-Lizenz), das dem Sekretariat nicht zusteht.
  #
  # Die Liste ist nicht auf erteilte Lizenzen verkürzt: Der Dialog blendet
  # Nicht-Erteilte selbst aus, zeigt aber weiterhin, wer trotzdem in der
  # Aufstellung steht – sonst ließe sich ein solcher Eintrag nicht mehr entfernen.
  def secretary_team_licenses_hash(team)
    players = Club.where(id: team.all_club_ids).flat_map(&:players).compact.uniq

    current_requests = players.filter_map do |player|
      license = player.licenses_by_team(team.id)
      next if license.blank?

      {
        id: player.id,
        last_name: player.last_name,
        first_name: player.first_name,
        birthdate: player.birthdate,
        current_status: secretary_license_status(player, license)
      }
    end

    { team: team.full_hash, current_requests: current_requests }
  end

  # Nur Kennung und Anzeigename des Status, nicht der Verlaufseintrag selbst.
  # Der trägt `reason` (Freitext einer Sperre oder Deaktivierung, z.B. aus
  # `Player#suspend!`), `created_by` und über `current_license_status` auch
  # `created_by_name`, also Name und Benutzername der verfügenden Stelle. Nichts
  # davon gehört an einen Link, der ohne Benutzerkonto offensteht. Gesperrte
  # Personen bleiben in `Player.active`, der Fall ist also erreichbar.
  #
  # `current_license_status` bleibt trotz des überflüssigen Namensaufrufs die
  # Quelle: Welcher Verlaufseintrag der neueste ist, soll an einer Stelle
  # entschieden werden, nicht hier ein zweites Mal.
  def secretary_license_status(player, license)
    status = player.current_license_status(license)
    return nil if status.blank?

    { license_status_id: status['license_status_id'].to_i,
      license_status: status[:license_status] }
  end

  # Kein `leagues`-Parameter mehr: Seit api#457 und api#460 leiten beide Verbraucher
  # ihre Ligaliste selbst aus dem Team ab (Team#express_license_league bzw.
  # Team#season_leagues), weil sie unterschiedlich gefiltert sein muss. Die
  # ungefilterte Liste des Aufrufers dient nur noch der Rechtepruefung, und die
  # bleibt bewusst ungefiltert: Die SBK einer Pokal-Liga darf den Kader lesen.
  def team_licenses_hash(team)
    result = {}

    result[:team] = team.full_hash

    # Maßgeblich ist der LV des Spielbetriebs der Liga, nicht der des Vereins:
    # Zuständig für den Spielbetrieb einer Liga ist allein deren Verband. Erlaubnis
    # und Zeitfenster müssen aus derselben Liga stammen (League#express_license_possible?).
    #
    # Auch hier die auslösende Liga mitgeben, nicht nur ein Ja/Nein: Der Verein
    # bestellt mit der Expresslizenz eine kostenpflichtige Leistung, und wer sie
    # abrechnet, hängt an dieser Liga. Ohne den Namen bestellt er bei einem Verband,
    # den er im Formular nie gesehen hat – häufig eine Pokal-Liga fremden Verbands.
    # Gleiche Wahl wie in PlayersController#request_license.
    express_league = team.express_license_league
    result[:express_license_enabled] = express_league.present?
    result[:express_license_league] = express_league && { id: express_league.id, name: express_league.name }
    # Elternzustimmung: wird pro Liga über das Flag parental_consent_required
    # gesteuert. Das Flag steuert den Datenschutz-Block im Antragsformular;
    # als Pflichtdokument steckt die Zustimmung in required_documents und wird
    # dort wie jede andere Dokumentart nach Alter aufgelöst.
    # Ersetzt die frühere is_buli-Ableitung über league_classes.
    #
    # Neben dem Ja/Nein die auslösende Liga mitgeben (Team#parental_consent_league,
    # gleiche Wahl wie in PlayersController#request_license): Das Formular soll
    # nennen können, wegen welcher Liga es die Zustimmung verlangt. Ohne den Namen
    # liest sich der Block wie eine Aussage über die Mannschaft insgesamt, obwohl
    # ihn eine einzelne Liga auslöst – oft eine Pokal-Liga eines anderen Verbands.
    consent_league = team.parental_consent_league
    result[:parental_consent_required] = consent_league.present?
    result[:parental_consent_league] = consent_league && { id: consent_league.id, name: consent_league.name }
    # season_leagues, nicht das ungefilterte `leagues`: Sonst greift der
    # Saisonfilter nur an einer Hälfte derselben Antwort. Eine liegengebliebene
    # Pokal-Liga aus einer abgeschlossenen Saison zöge ihre Pflichtdokumente
    # weiter in die laufende — und im Fall der Elternzustimmung entstünde genau
    # der Widerspruch, den parental_consent_league beseitigen soll: Der
    # Datenschutz-Block verschwindet, während die Upload-Zeile "Zustimmung der
    # Erziehungsberechtigten" als offene Pflicht stehen bleibt, ohne dass das
    # Formular noch sagt, welche Liga sie verlangt.
    result[:required_documents] = team.season_leagues.flat_map { |l| league_required_document_keys(l) }.uniq
    # Katalog-Metadaten (Name, Vorlage, Gültigkeit, Altersgrenze) zu den
    # geforderten Dokumentarten – fürs Upload-UI im Team-Lizenzwesen.
    catalog = document_type_catalog(result[:required_documents] + ['parental_consent'])
    result[:document_types] = catalog.values.sort_by(&:name).map { |dt| document_type_json(dt) }

    clubs = Club.find(team.all_club_ids)
    all_players = clubs.map(&:players).flatten.compact

    result[:current_requests] = []
    result[:other_players] = []

    all_players.each do |p|
      l = p.licenses_by_team(team.id)
      if l.present?
        item = p.full_hash
        item[:team_license] = l
        cs = p.current_license_status(l)
        item[:current_status] = cs
        item[:can_withdraw] = (cs['license_status_id'] == License::REQUESTED)
        # Dieselbe Auswahl wie in PlayersController#withdraw_license_request. Liefe
        # die Anzeige nach einer anderen Regel, versprach die Seite ein
        # kostenfreies Zurückziehen ("kostenfrei bis …", eigener Linktext), das
        # die Aktion nicht einlöst.
        #
        # Bewusst nicht license_requested_at weiter unten: Die Altersgrenzen der
        # Pflichtdokumente hängen weiter am jüngsten Antrag, unabhängig davon,
        # wer ihn geschrieben hat.
        last_requested = License.grace_period_anchor(l['history'])
        item[:grace_period_ends_at] = last_requested ? (last_requested['created_at'].to_time + License::GRACE_PERIOD).iso8601 : nil
        # Altersabhängige Dokumentarten: Arten mit required_below_age rechnen gegen das
        # Datum der Lizenzbeantragung, Arten mit required_from_birth_year sehen es nicht
        # an (siehe DocumentType#required_for?).
        item[:required_documents] = DocumentType.required_keys(
          result[:required_documents],
          birthdate: p.birthdate,
          requested_at: license_requested_at(l),
          catalog: catalog
        )
        result[:current_requests] << item
      else
        result[:other_players] << p.meta_hash
      end
    end

    result
  end

  # Gemeinsam für Anlage und Änderung. `state_association_id` ordnet den Verein
  # ein und bestimmt damit den zuständigen Spielbetrieb; ein eigener
  # Spielbetriebs-Parameter gibt es nicht mehr (siehe create_club / update_club).
  def club_params
    params.require(:club).permit(:name, :short_name, :long_name, :state, :state_association_id, :contact_email,
                                 :team_managers_manage_players, notify_user_ids: [])
  end

  # Vereinsmanager-Fassung: ohne die Felder, die den Verein einordnen.
  # `state` und `state_association_id` entscheiden mit darüber, wer den Verein
  # verwalten und wer seine Spieler sperren darf – ein Verein könnte sich sonst
  # selbst in einen anderen Landesverband umhängen.
  # `team_managers_manage_players` steht bewusst in BEIDEN Fassungen: Wer die
  # Rechte im Verein vergibt, ist der Verein selbst, und der Vereinsmanager ist
  # genau die Rolle, die den Schalter braucht. Ein Feld, das die
  # Vereinsverwaltung anzeigt, aber nur der Verband schreiben kann, wäre für
  # ihn eine Maske ohne Wirkung (und `restricted_field_conflict` müsste es dann
  # als Konflikt melden).
  def restricted_club_params
    params.require(:club).permit(:name, :short_name, :long_name, :contact_email,
                                 :team_managers_manage_players, notify_user_ids: [])
  end

  def full_club_access?(club)
    club.user_permissions(current_user).include?(:update_club)
  end

  # Felder, die der eingeschränkte Zugriff nicht schreibt. Kommt eines davon
  # mit einem ANDEREN Wert an, ist das keine harmlose Rücksendung des Formulars,
  # sondern ein Änderungswunsch, der sonst stillschweigend verfiele.
  RESTRICTED_FIELDS = %w[state state_association_id].freeze

  # Liefert die Meldung, wenn ein eingeschränkter Zugriff eines der
  # vorbehaltenen Felder ändern will – sonst nil.
  #
  # Ohne diese Prüfung antwortete das Speichern mit 200 und einer
  # Erfolgsmeldung, während `restricted_club_params` die Felder verwarf. Das
  # trifft nicht nur den Vereinsmanager: Wer eine Spielbetriebsrolle für einen
  # Verband UND eine Vereinsrolle für einen Verein aus einem anderen Verband
  # hat, bekommt das Formular unbeschränkt zu sehen (das Frontend-Flag gilt pro
  # Benutzer), die Berechtigung entscheidet aber pro Verein.
  def restricted_field_conflict(club)
    eingereicht = params[:club] || {}

    geaendert = RESTRICTED_FIELDS.select do |feld|
      next false unless eingereicht.key?(feld)

      # Vergleich über to_s: state_association_id kommt als String an, steht in
      # der Spalte aber als Integer.
      eingereicht[feld].to_s.presence != club.public_send(feld).to_s.presence
    end

    return nil if geaendert.empty?

    'Bundesland und Landesverband ordnen den Verein ein und können nur vom ' \
      'zuständigen Verband geändert werden.'
  end

  # Der Landesverband entscheidet, welcher Spielbetrieb den Verein verwaltet
  # (Club#main_game_operation_id). Ein Wechsel muss deshalb auch am ZIEL erlaubt
  # sein: `:update_club` gilt nur für den bisher zuständigen Spielbetrieb, und
  # ohne diese Prüfung könnte ein Verband einen Verein in einen fremden Verbund
  # schieben, der ihn nie aufgenommen hat – und verlöre dabei selbst den Zugriff.
  #
  # Dieselbe Prüfung hing vorher am Feld `game_operation_id`. Sie musste
  # mitwandern, weil das Feld entfallen ist: Sonst wäre aus einer bewachten
  # Änderung eine unbewachte geworden, und zwar ohne dass es irgendwo aufgefallen
  # wäre – `state_association_id` galt bisher als reines Einordnungsfeld.
  #
  # Gibt nil zurück, wenn nichts zu beanstanden ist, sonst die Meldung.
  def state_association_move_conflict(club)
    eingereicht = params[:club] || {}
    return nil unless eingereicht.key?('state_association_id')

    ziel_sa_id = eingereicht['state_association_id'].presence&.to_i
    return nil if ziel_sa_id == club.state_association_id

    global = current_user.permission_hash.values_at(:admin, :sbk).any? { |ids| Array(ids).include?(0) }

    # Ohne Landesverband ist für den Verein kein Spielbetrieb zuständig, er
    # erscheint danach nur noch im globalen Zugriff. Wer selbst global sieht, darf
    # das (auf Produktion standen am 19.08.2026 vier Ablage-Vereine so da); ein
    # einzelner Verband würde den Verein damit für sich und alle anderen
    # unerreichbar machen.
    if ziel_sa_id.nil?
      return nil if global

      return 'Ohne Landesverband ist kein Verband für den Verein zuständig. ' \
             'Das kann nur die Bundesebene setzen.'
    end

    ziel_wurzel_id = StateAssociation.root_id(ziel_sa_id)

    # Eine Kennung, die es nicht gibt, ist ein anderer Fehler als ein Verband
    # ohne Spielbetrieb, und die Meldung muss das sagen: Sonst wird jemand
    # aufgefordert, einen Spielbetrieb anzulegen, obwohl er nur einen gültigen
    # Verband auswählen muss. Die Anlage unterscheidet beides schon
    # (state_association_error_message), das Bearbeiten warf sie zusammen.
    return 'Der gewählte Landesverband existiert nicht.' if ziel_wurzel_id.nil?

    ziel_go_id = GameOperation.id_by_state_association[ziel_wurzel_id]

    # Ein Landesverband, dessen Verbund keinen Spielbetrieb hat, hinterlässt
    # denselben unerreichbaren Verein wie ein leeres Feld – nur unauffälliger,
    # weil in der Maske ein Verband ausgewählt ist. Genau so kam es zu dem Fall,
    # der diese Umstellung ausgelöst hat. Deshalb auch für die Bundesebene ein
    # Riegel: Erst braucht der Verbund einen Spielbetrieb (Issue #492).
    if ziel_go_id.nil?
      return 'Für diesen Landesverband gibt es keinen Spielbetrieb. Der Verein ' \
             'hätte danach keinen zuständigen Verband.'
    end

    return nil if global || ziel_go_id == club.main_game_operation_id

    ziel_go = GameOperation.find_by(id: ziel_go_id)
    return nil if ziel_go&.user_permissions(current_user)&.include?(:create_club)

    'Keine Berechtigung für den Ziel-Spielbetrieb'
  end

  # Vereinsänderung. Ein `game_operation_id` im Rumpf wird nicht mehr gelesen:
  # Der Landesverband ordnet den Verein ein, der zuständige Spielbetrieb ergibt
  # sich daraus (Club#main_game_operation_id). Das Feld darf mitkommen, ohne die
  # Anfrage zu stören – das Formular schickt den Verein unverändert zurück.
  def update_club(club)
    club.updated_by = current_user.id

    # Einmal auswerten und wiederverwenden: `full_club_access?` leitet die
    # Berechtigung über den Landesverband ab, und der wird unten geschrieben. Ein
    # zweiter Aufruf beantwortete die Frage danach für den ZIEL-Verband statt für
    # den, der die Anfrage autorisiert hat.
    voller_zugriff = full_club_access?(club)

    if !voller_zugriff && (meldung = restricted_field_conflict(club))
      return render json: { success: false, message: meldung }, status: :forbidden
    end

    if voller_zugriff && (meldung = state_association_move_conflict(club))
      return render json: { success: false, message: meldung }, status: :forbidden
    end

    if club.update(voller_zugriff ? club_params : restricted_club_params)
      render json: club.full_hash
    else
      render json: club.errors, status: :unprocessable_entity
    end
  end

  # Ohne Landesverband kein Verein: aus ihm ergibt sich, wer den Verein verwalten
  # darf. Die Auswahl ersetzt das frühere Spielbetriebs-Feld, das nur bei der
  # Neuanlage sichtbar war und beim Bearbeiten unerreichbar blieb.
  def create_club
    game_operation = resolve_create_game_operation

    if game_operation.nil?
      return render json: { success: false, message: state_association_error_message },
                    status: :unprocessable_entity
    end

    unless game_operation.user_permissions(current_user).include?(:create_club)
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    club = Club.new(club_params)
    club.created_by = current_user.id
    club.updated_by = current_user.id

    # Ergebnis prüfen: Club.create gab vorher auch einen ungespeicherten Verein
    # zurück, den die Antwort als 201 Created auswies.
    if club.save
      render json: club.full_hash, status: :created
    else
      render json: club.errors, status: :unprocessable_entity
    end
  end

  # Der Spielbetrieb, der für den neuen Verein zuständig wäre, abgeleitet aus dem
  # gewählten Landesverband. nil heißt „kein Verband zuständig" und führt zur
  # Meldung, statt einen Verein anzulegen, den anschließend nur noch die
  # Bundesebene sieht (`Club.unassigned`) und der sonst niemandem gehört.
  def resolve_create_game_operation
    sa_id = (params[:club] || {})[:state_association_id].presence
    return nil if sa_id.nil?

    go_id = GameOperation.id_by_state_association[StateAssociation.root_id(sa_id)]
    GameOperation.find_by(id: go_id)
  end

  # Unterscheidet die drei Gründe. Vorher nannten die ersten beiden dieselbe
  # Meldung, obwohl nur der erste vom Nutzer kommt.
  def state_association_error_message
    sa_id = (params[:club] || {})[:state_association_id].presence
    return 'Bitte einen Landesverband auswählen.' if sa_id.nil?
    return 'Der gewählte Landesverband existiert nicht.' if StateAssociation.root_id(sa_id).nil?

    'Für diesen Landesverband gibt es keinen Spielbetrieb. Der Verein hätte ' \
      'keinen zuständigen Verband.'
  end

  # Ein Verein kann Teams in Ligen mehrerer Spielbetriebe haben (Gastvereine
  # anderer Landesverbände). Nur die Teams anzeigen, für die die eigene Rolle im
  # Lizenzwesen auch etwas tun darf, sonst führt die Auswahl ins 403. Rollen
  # additiv, damit ein SBK mit VM-Rolle die Teams seines eigenen Vereins
  # außerhalb seines Spielbetriebs behält. Für SBK zählt die primäre Liga
  # (`sbk_can_access_team?`), also derselbe Scope, den das Beantragen
  # anschließend prüft; `team.leagues` wäre hier ein N+1.
  # Vereine, die ein Admin-/SBK-Scope in seinen Listen sehen soll. Drei Quellen,
  # und der frühere `GameOperation#clubs` (= ganzer game_operations_hash) ist
  # keine davon:
  #
  # 1. Zustaendiger Spielbetrieb – die eigenen Vereine.
  # 2. Vereins-Freigabe – ausdrücklich erteilt, saisongebunden, pflegbar.
  # 3. Vereine mit einer Mannschaft in einer eigenen Liga dieser Saison.
  #
  # Punkt 3 ersetzt den Gast-Eintrag im Hash, und zwar genauer: Der Hash stammte
  # aus dem Altdaten-Import 2010–2014, wurde nie nachgeführt und war auf
  # Produktion zu 85 % nicht mehr durch eine Liga gedeckt. Die Liga-Ableitung
  # ist immer aktuell und deckt Gastmannschaften auch dann ab, wenn deren
  # Landesverband nichts freigegeben hat – ohne dass daraus Zugriff auf die
  # Vereinsstammdaten entsteht: Die Mannschaftsliste wird anschließend über
  # `may_list_team?` gefiltert (liga-basiert), und Stammdaten hängen an
  # `Club#readable_by_game_operations?` bzw. `Club#user_permissions`.
  def clubs_for_game_operations(go_ids)
    go_ids = Array(go_ids).compact.map(&:to_i).uniq
    return [] if go_ids.empty?

    # where(id:) statt find: kein Absturz, wenn eine Berechtigung auf einen
    # zwischenzeitlich gelöschten Spielbetrieb verweist.
    own = GameOperation.where(id: go_ids).flat_map(&:home_clubs)

    released_sa_ids = StateAssociationRelease.current_season
                                             .where(recipient_game_operation_id: go_ids)
                                             .pluck(:grantor_state_association_id)
    released = released_sa_ids.any? ? Club.where(state_association_id: released_sa_ids).to_a : []

    guests = Club.where(id: club_ids_with_team_in_game_operations(go_ids)).to_a

    (own + released + guests).uniq
  end

  # Vereins-IDs, die in der aktuellen Saison eine Mannschaft in einer Liga der
  # gegebenen Spielbetriebe haben. `all_club_ids` nimmt SG-Partnervereine mit.
  def club_ids_with_team_in_game_operations(go_ids)
    Team.current_season
        .joins(:league)
        .where(leagues: { game_operation_id: go_ids })
        .flat_map(&:all_club_ids)
        .uniq
  end

  def may_list_team?(ph, club, team)
    ph[:admin].present? ||
      sbk_can_access_team?(ph, team) ||
      (ph[:vm].present? && ph[:vm].include?(club.id)) ||
      (ph[:tm].present? && ph[:tm].include?(team.id))
  end

  # Alle Teams der aktuellen Saison für die gegebenen Vereine in einer
  # Abfrage, gruppiert nach Vereins-ID (Stamm-Verein UND SG-Partnervereine –
  # gleiche Semantik wie Team.by_club_id je Verein). Ligen, Spielbetriebe
  # und Logos werden für Team#full_hash gleich mitgeladen.
  def current_teams_by_club(club_ids)
    base = Team.current_season
    teams = base.where(club_id: club_ids)
                .or(base.where('syndicate_clubs && ARRAY[?]::integer[]', club_ids))
                .includes(league: :game_operation,
                          club: { logo_attachment: :blob },
                          logo_attachment: :blob)

    teams.each_with_object(Hash.new { |h, k| h[k] = [] }) do |team, by_club|
      ([team.club_id] + team.syndicate_clubs.to_a).uniq.each do |club_id|
        by_club[club_id] << team
      end
    end
  end

  def can_read_admin_club?(club)
    return true if club.user_permissions(current_user).include?(:update_own_club)

    ph = current_user.permission_hash
    go_ids = (ph[:admin].to_a + ph[:sbk].to_a).reject(&:zero?)
    return false if go_ids.empty?

    # Zustaendiger Spielbetrieb oder Vereins-Freigabe – gemeinsame Regel mit
    # Club.admin_user_clubs und Player.admin_user_players.
    #
    # Der frühere Zweig „hängt als Gast-Spielbetrieb am Verein" ist bewusst
    # entfallen. Gast-Einträge im game_operations_hash wurden von der Anwendung
    # nie geschrieben – einzige Quelle war der Altdaten-Import 2010–2014, der sie
    # inzwischen selbst nicht mehr schreibt – und sie wurden auch nicht nachgeführt, wenn
    # eine Mannschaft die Liga wechselt. Auf Produktion waren 183 von 220
    # Gast-Einträgen durch keine aktuelle Liga mehr gedeckt; sie öffneten
    # Landesverbänden gegenseitig die Vereinsstammdaten, ohne dass das jemand
    # erteilt hätte oder zurücknehmen könnte.
    #
    # Wer eine Gastmannschaft in seiner Liga betreut, braucht dafür keinen
    # Zugriff auf die Vereinsstammdaten: Mannschaft und Lizenzen hängen an
    # `league.game_operation_id` (LicenseAccessScope), nicht am Verein.
    club.readable_by_game_operations?(go_ids)
  end
end
