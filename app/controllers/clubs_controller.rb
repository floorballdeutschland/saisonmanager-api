class ClubsController < ApplicationController
  include LicenseDocumentPresentation
  include LicenseAccessScope

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
      item
    }
  end

  def user_team_licenses
    ph = current_user.permission_hash

    team = Team.find(params[:id])

    # get leagues for team
    leagues = team.leagues
    # get playing clubs, including sg
    teams = leagues.map(&:teams).flatten.compact.uniq
    club_ids = teams.map(&:all_club_ids).flatten.compact.uniq
    # get hosting clubs
    all_club_ids = [club_ids, leagues.map { |l| l.game_days.map(&:club_id) }].flatten.compact.uniq

    # Rollen additiv: ein VM, der zugleich TM eines Teams außerhalb seiner
    # Vereine ist, wurde von der elsif-Kette sonst am TM-Zweig vorbeigeleitet.
    allowed = ph[:admin].present? || sbk_can_access_leagues?(ph, leagues) ||
              # vm: permission for one of those clubs?
              (ph[:vm].present? && ph[:vm].intersection(all_club_ids).present?) ||
              # tm: get clubs for league teams of given team, permission for one of those?
              (ph[:tm].present? && ph[:tm].intersection(teams.map(&:id)).present?)

    if allowed
      result = {}

      result[:team] = team.full_hash

      # Maßgeblich ist der LV des Spielbetriebs der Liga, nicht der des Vereins:
      # Zuständig für den Spielbetrieb einer Liga ist allein deren Verband. Erlaubnis
      # und Zeitfenster müssen aus derselben Liga stammen (League#express_license_possible?).
      result[:express_license_enabled] = leagues.any?(&:express_license_possible?)
      # Elternzustimmung: wird pro Liga über das Flag parental_consent_required
      # gesteuert (löst nur noch zusammen mit Minderjährigkeit im Frontend die
      # Pflicht aus). Ersetzt die frühere is_buli-Ableitung über league_classes.
      result[:parental_consent_required] = leagues.any?(&:parental_consent_required)
      result[:required_documents] = leagues.flat_map { |l| l.required_documents || [] }.uniq
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
          last_requested = l['history'].select { |h| h['license_status_id'].to_i == License::REQUESTED }
                                       .max_by { |h| h['created_at'] }
          item[:grace_period_ends_at] = last_requested ? (last_requested['created_at'].to_time + License::GRACE_PERIOD).iso8601 : nil
          # Altersabhängige Dokumentarten: Stichtag = Datum der Lizenzbeantragung.
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

      render json: result
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
        # sind Altlast aus dem Import 2010–2014 (siehe can_read_admin_club?).
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
        league_club_ids = Team.where(league_id: league.id).flat_map(&:all_club_ids).uniq
        render json: Club.where(id: (own_ids + released_ids + league_club_ids).uniq)
                         .order(:name).map(&:full_hash)
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
  def admin_club_all
    ph = current_user.permission_hash
    unless %i[admin sbk vm tm rsk ansetzer].any? { |role| ph[role].present? }
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    clubs = Club.includes(logo_attachment: :blob).order(:name)
    render json: clubs.map(&:public_hash)
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

    club.deactivate!(current_user.id)
    render json: club.full_hash
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
  # nur Admin/SBK des Spielbetriebs (analog :update_club) sowie LV-Rollen mit
  # aktueller Vereins-Freigabe (StateAssociationRelease, Lesezugriff wie in
  # Club.admin_user_clubs).
  def admin_club
    if current_user
      club = Club.find(params[:id])

      unless can_read_admin_club?(club)
        return render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

      render json: club.full_hash
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
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
      elsif (club = Club.find(params[:id])).user_permissions(current_user).include?(:update_club)
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

      unless club.user_permissions(current_user).include?(:update_club)
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

  # Gemeinsam für Anlage und Änderung. Der Spielbetrieb fehlt hier bewusst: er
  # ist keine Spalte am Verein, sondern ein Eintrag im game_operations_hash, und
  # kommt deshalb als eigener Parameter (siehe create_club / update_club).
  def club_params
    params.require(:club).permit(:name, :short_name, :long_name, :state, :state_association_id, :contact_email)
  end

  # Vereinsänderung. Der Spielbetrieb ist optional – kommt er mit, wird der
  # Heimat-Eintrag ersetzt.
  def update_club(club)
    club.updated_by = current_user.id

    # `present?` statt `key?`: Das Formular schickt den ganzen Verein zurück,
    # also auch ein `game_operation_id`, das es dort gar nicht zu bearbeiten
    # gibt. Bei einem Verein ohne Heimat-Eintrag liefert Club#full_hash dafür
    # nil, und `key?` verstand dieses nil als „soll geändert werden" – das
    # Speichern scheiterte an der Prüfung unten, obwohl niemand etwas ändern
    # wollte. Betroffen waren ausgerechnet die Vereine ohne Spielbetrieb, also
    # die, deren Stammdaten am dringendsten Pflege brauchen.
    #
    # Eine ausdrückliche 0 oder eine unbekannte Kennung laufen weiterhin in die
    # Meldung: in Ruby ist `0.present?` true, nur nil und "" gelten hier als
    # „nicht mitgeschickt".
    if params[:game_operation_id].present?
      target = resolve_game_operation(params[:game_operation_id])

      # Eine 0 oder eine unbekannte ID hätte den Heimat-Eintrag auf einen
      # Spielbetrieb gesetzt, den es nicht gibt. Der Verein wäre danach in
      # keiner Vereinsliste mehr aufgetaucht (die Abfragen matchen per jsonb
      # gegen eine echte ID) und über die Oberfläche nicht mehr auffindbar.
      if target.nil?
        return render json: { success: false, message: game_operation_error_message },
                      status: :unprocessable_entity
      end

      # Wechselt der Heimat-Spielbetrieb, muss die Berechtigung auch am Ziel
      # bestehen. `:update_club` gilt nur für den bisherigen Spielbetrieb – ohne
      # diese Prüfung konnte ein Verband einen Verein in einen fremden
      # Spielbetrieb verschieben, der ihn nie aufgenommen hat, und der bisherige
      # Verband verlor dabei den Zugriff.
      if target.id != club.main_game_operation_id &&
         !target.user_permissions(current_user).include?(:create_club)
        return render json: { message: 'Keine Berechtigung für den Ziel-Spielbetrieb' },
                      status: :forbidden
      end

      # Der Hash trägt nur noch den Heimat-Eintrag. Vorher wurden hier zusätzlich
      # die Gast-Einträge des Altdaten-Imports mitgeschleift.
      club.game_operations_hash = [{ 'home_game_operation' => true, 'game_operation_id' => target.id }]
    end

    if club.update(club_params)
      render json: club.full_hash
    else
      render json: club.errors, status: :unprocessable_entity
    end
  end

  def create_club
    game_operation = resolve_create_game_operation

    # Ohne Spielbetrieb kein Verein: der Heimat-Spielbetrieb entscheidet, wer
    # den Verein verwalten darf. Vorher lief hier GameOperation.find(0) in einen
    # RecordNotFound, und der Nutzer bekam „Nicht gefunden." – eine Meldung, die
    # nach einem fehlenden Verein klingt.
    if game_operation.nil?
      return render json: { success: false, message: game_operation_error_message },
                    status: :unprocessable_entity
    end

    unless game_operation.user_permissions(current_user).include?(:create_club)
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    club = Club.new(club_params)
    # game_operation_id bewusst als Integer: alle Abfragen auf den
    # game_operations_hash vergleichen per jsonb `@>` gegen eine Zahl. Als String
    # gespeichert (params sind Strings) findet den Verein keine dieser Abfragen –
    # er fehlte anschließend in der Vereinsverwaltung.
    club.game_operations_hash = [{ 'home_game_operation' => true,
                                   'game_operation_id' => game_operation.id }]
    club.created_by = current_user.id
    club.updated_by = current_user.id

    # Ergebnis prüfen: Club.create gab vorher auch einen ungespeicherten Verein
    # zurück, den die Antwort als 201 Created auswies. Club hat derzeit keine
    # Validierungen, der Zweig ist also Vorsorge – und deshalb ohne Test.
    if club.save
      render json: club.full_hash, status: :created
    else
      render json: club.errors, status: :unprocessable_entity
    end
  end

  def resolve_create_game_operation
    resolve_game_operation(params[:game_operation_id])
  end

  # `find_by` statt `find`, damit eine unbekannte ID zu einer verständlichen
  # Meldung führt statt zu einem 404 („Nicht gefunden." aus dem globalen
  # rescue_from, was nach einem fehlenden Verein klingt).
  def resolve_game_operation(raw_id)
    go_id = raw_id.to_i
    return nil unless go_id.positive?

    GameOperation.find_by(id: go_id)
  end

  # Unterscheidet die beiden Gründe: nicht ausgewählt oder unbekannt. Vorher
  # nannte beide Fälle dieselbe Meldung, obwohl nur der erste vom Nutzer kommt.
  def game_operation_error_message
    if params[:game_operation_id].to_i.positive?
      'Der gewählte Spielbetrieb existiert nicht.'
    else
      'Bitte einen Spielbetrieb auswählen.'
    end
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
  # 1. Heimat-Spielbetrieb – die eigenen Vereine.
  # 2. Vereins-Freigabe – ausdrücklich erteilt, saisongebunden, pflegbar.
  # 3. Vereine mit einer Mannschaft in einer eigenen Liga dieser Saison.
  #
  # Punkt 3 ersetzt den Gast-Eintrag im Hash, und zwar genauer: Der Hash stammt
  # aus dem Altdaten-Import 2010–2014, wird nie nachgeführt und war auf
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
    return true if club.user_permissions(current_user).include?(:update_club)

    ph = current_user.permission_hash
    go_ids = (ph[:admin].to_a + ph[:sbk].to_a).reject(&:zero?)
    return false if go_ids.empty?

    # Heimat-Spielbetrieb oder Vereins-Freigabe – gemeinsame Regel mit
    # Club.admin_user_clubs und Player.admin_user_players.
    #
    # Der frühere Zweig „hängt als Gast-Spielbetrieb am Verein" ist bewusst
    # entfallen. Gast-Einträge im game_operations_hash werden von der Anwendung
    # nie geschrieben – einzige Quelle ist der Altdaten-Import 2010–2014
    # (import_legacy_data.rake) – und sie werden auch nicht nachgeführt, wenn
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
