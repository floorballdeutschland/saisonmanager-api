module Admin
  class LicenseDocumentsController < ApplicationController
    # sbk_can_access_license? / sbk_global? – Scope über die Liga der Lizenz.
    include LicenseAccessScope
    # Dieselbe Auflösung der Pflichtdokumente wie in den Lizenzansichten:
    # league_required_document_keys, license_requested_at und
    # document_type_catalog. Die Concern bringt weitere Helfer mit
    # (license_documents_by_player_and_type, document_map_for, current_document,
    # document_type_json), die hier ungenutzt bleiben. Weil
    # document_type_catalog(keys) belegt ist, heißt der lokale Helfer, der
    # Dokumente nimmt und den Verband mitlädt, catalog_for.
    include LicenseDocumentPresentation

    before_action :set_player
    before_action :check_read_permission, only: %i[index show available_types]
    before_action :check_write_permission, only: %i[create]
    before_action :check_delete_permission, only: %i[destroy]

    # Dokumentarten, die für DIESEN Spieler hochgeladen werden können – die
    # Auswahlliste für den Upload am Spielerprofil. Der Katalog-Abruf
    # (Admin::DocumentTypesController#index) taugt dafür nicht: Er ist auf Admin
    # und SBK beschränkt und kennt den Spieler nicht.
    def available_types
      # template_attachment/blob mitladen: template_url_for fragt je Art
      # template.attached? und die Blob-Adresse ab, das waren sonst ein bis zwei
      # Abfragen pro Dokumentart bei jedem Öffnen eines Spielerprofils.
      types = DocumentType.for_game_operations(player_home_game_operation_ids)
                          .includes(:game_operation, template_attachment: :blob)
                          .order(:name)
                          .to_a
      types = types.select { |dt| type_available?(dt) }
      render json: types.map { |dt| available_type_json(dt) }
    end

    def index
      # Dokumente gelten pro Spieler (saisonübergreifend), die Abfrage holt
      # deshalb alle Dokumente des Spielers – license_id filtert hier nicht.
      scope = @player.license_documents
      # Voreinstellung ist der aktuelle Bestand. Archivierte Fassungen kommen
      # nur auf ausdrückliche Anforderung mit, sonst stünden abgelöste und
      # gelöschte Dokumente in der Oberfläche wie aktuelle Nachweise.
      scope = scope.active unless include_archived?
      docs = scope.includes(:archived_by, file_attachment: :blob).order(created_at: :desc).to_a
      catalog = catalog_for(docs)
      docs = filter_documents_by_scope(docs, catalog)
      render json: docs.map { |d| document_json(d, catalog) }
    end

    def show
      doc = @player.license_documents.find(params[:id])
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless document_visible?(doc)

      # Ein Datensatz ohne Anhang ist ein Defekt (verlorener Blob, abgebrochener
      # Upload). Seit der Archivierung überdauert er das Ersetzen, statt mit ihm
      # zu verschwinden – ohne diese Abfrage stürbe der Abruf an
      # `rails_blob_url(nil)`.
      if doc.archived? && !verband?
        return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
      end

      unless doc.file.attached?
        return render json: { message: 'Zu diesem Dokument liegt keine Datei vor.' }, status: :not_found
      end

      redirect_to rails_blob_url(doc.file, disposition: 'inline'), allow_other_host: true
    end

    def create
      return render json: { errors: ['Datei fehlt'] }, status: :unprocessable_entity if params[:file].blank?

      # Genau eine Dokumentart, als Zeichenkette. Die Typprüfung ist nicht
      # kosmetisch: `document_type[]=global&document_type[]=fremd` kam als Array
      # an, und damit ließ sich beides aushebeln, was diese Aktion schützt.
      # `find_by(key: [...])` liefert irgendeinen Treffer der Liste (in der Praxis
      # den globalen), die Scope-Prüfung unten winkt also durch; und die
      # Ersetzungs-Abfrage `where(document_type: [...])` löst die Dokumente
      # ALLER genannten Arten ab, auch die eines fremden Verbands. Gespeichert wurde
      # anschließend eine Zeile mit dem Array als Text.
      document_type = params[:document_type]
      unless document_type.is_a?(String) && document_type.present?
        return render json: { errors: ['Dokumenttyp fehlt'] }, status: :unprocessable_entity
      end

      unless document_type_in_scope?(document_type)
        return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
      end

      doc = LicenseDocument.new(
        player: @player,
        license_id: params[:license_id].presence,
        document_type: document_type,
        season_id: Setting.current_season_id,
        uploaded_by: current_user
      )
      doc.file.attach(params[:file])

      # Pro Spieler gibt es je Dokumentart genau ein aktuelles Dokument – ein
      # neuer Upload löst alle vorhandenen dieser Art ab (auch Altbestand, der
      # noch an einer konkreten Lizenz hing). Erst archivieren, dann validieren:
      # sonst schlägt die Eindeutigkeits-Validierung gegen das abzulösende
      # Dokument an. Bei ungültigem Upload rollt die Transaktion die
      # Archivierung zurück, der Bestand bleibt unverändert.
      #
      # Archiviert statt gelöscht, damit die abgelöste Fassung samt Anhang
      # nachweisbar bleibt: Bis hierher verschwand mit dem Ersetzen auch die
      # Grundlage jeder Lizenz, die auf dem alten Dokument erteilt worden war.
      existing = @player.license_documents.active.where(document_type: document_type)
      saved = false
      begin
        ActiveRecord::Base.transaction do
          existing.find_each { |old| old.archive!(reason: 'replaced', user: current_user) }
          saved = doc.save
          raise ActiveRecord::Rollback unless saved
        end
      rescue ActiveRecord::RecordNotUnique
        # Zwei gleichzeitige Uploads derselben Art mit gesetzter license_id: Der
        # partielle Index faengt den zweiten ab, nachdem die Validierung ihn
        # durchgelassen hat (sie las den Bestand vor der ersten Transaktion).
        # Ohne diese Behandlung antwortete die Maske mit einem nackten 500.
        return render json: { errors: ['Zu dieser Dokumentart wurde soeben schon eine Datei hochgeladen. ' \
                                       'Bitte die Ablage neu laden.'] },
                      status: :conflict
      end

      unless saved
        return render json: { errors: doc.errors.full_messages }, status: :unprocessable_entity
      end

      render json: document_json(doc, catalog_for([doc])), status: :created
    end

    # Löschen heißt nicht mehr in jedem Fall vernichten. Beruht eine ERTEILTE
    # Lizenz auf dem Dokument, bleibt es als archivierte Fassung stehen: Der
    # Verein verliert es aus seiner Ablage, der Verband kann weiterhin belegen,
    # worauf er die Lizenz erteilt hat. Endgültig löschen kann nur Admin – auch
    # eine bereits archivierte Fassung.
    def destroy
      doc = @player.license_documents.find(params[:id])
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless document_visible?(doc)

      if admin?
        purge_document(doc)
      elsif doc.archived?
        # Archiviert ist archiviert: Sonst ließe sich der Nachweis in zwei
        # Schritten beseitigen – erst ersetzen, dann die alte Fassung löschen.
        render json: { message: 'Archivierte Nachweise kann nur die Administration löschen.' },
               status: :forbidden
      elsif relied_upon_by_approved_license?(doc)
        doc.archive!(reason: 'deleted', user: current_user)
        render json: { success: true, archived: true }
      else
        purge_document(doc)
      end
    end

    private

    def set_player
      @player = Player.find(params[:player_id])
    end

    def check_read_permission
      return if admin_or_sbk_for_player?
      return if vm_for_player?
      return if tm_for_player?

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    def check_write_permission
      return if admin_or_sbk_for_player?
      return if vm_for_player?
      return if tm_for_player?

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    # Löschen ist nicht Hochladen, und für den Teammanager fällt beides ab
    # hier auseinander.
    #
    # Der neue Vereinsweg (`tm_club_ids`) ist dafür gedacht, Nachweise
    # NACHZUTRAGEN — er hebt die Bedingung „es gibt schon eine Lizenz auf
    # genau meiner Mannschaft" auf, damit der Upload zu Saisonbeginn überhaupt
    # möglich ist. Am Löschen hängt aber die Gegenrichtung: Solange keine
    # ERTEILTE Lizenz auf dem Dokument beruht, vernichtet #destroy es
    # endgültig (`purge_document`), und genau dieser Zustand ist der
    # Saisonbeginn. Über den Vereinsweg käme damit jede Teammanagerin an die
    # Zustimmung der Erziehungsberechtigten einer Jugendspielerin einer
    # anderen Mannschaft ihres Vereins — ein Recht, das sie vorher nicht
    # hatte und das weder der Titel dieses Vorgangs noch das Handbuch
    # zusagen („hochladen, ansehen und ersetzen").
    #
    # Ersetzen bleibt möglich: Das läuft über #create, das die abgelöste
    # Fassung archiviert statt sie zu löschen.
    #
    # Für Verband und Vereinsmanager ändert sich nichts, deren Regeln sind
    # unverändert.
    def check_delete_permission
      return if admin_or_sbk_for_player?
      return if vm_for_player?
      return if tm_license_team_for_player?

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    # Zwei Gründe, beide zulässig:
    #
    # (a) Der Spieler gehört einem Verein, den dieser Spielbetrieb lesen darf
    #     (zustaendiger Spielbetrieb oder Vereins-Freigabe) – der bisherige Weg, nur
    #     ohne die Gast-Einträge aus dem Altdaten-Import 2010–2014.
    # (b) Eine seiner Lizenzen hängt an einer Liga dieses Spielbetriebs.
    #
    # (b) ist neu und behebt einen Widerspruch: Eine SBK durfte die Lizenz einer
    # Gastmannschaft in ihrer eigenen Liga genehmigen (liga-basiert über
    # LicenseAccessScope), die dafür geforderten Pflichtdokumente aber nicht
    # einsehen – es sei denn, im Vereins-Hash stand zufällig ein Gast-Eintrag.
    # Wer genehmigt, muss die Dokumente sehen.
    def admin_or_sbk_for_player?
      ph = perm_hash
      return true if ph[:admin].present?
      return false if ph[:sbk].blank?
      return true if sbk_global?(ph)

      return true if player_clubs_readable?(ph)

      # Bei gesetztem license_id nur diese Lizenz, sonst genügt eine Lizenz im
      # eigenen Spielbetrieb.
      scoped_licenses.any? { |license| sbk_can_access_license?(ph, license) }
    end

    def player_clubs_readable?(ph)
      go_ids = ph[:sbk].to_a.reject(&:zero?)
      return false if go_ids.empty?

      club_ids = (@player.clubs || []).filter_map { |c| c['club_id']&.to_i }
      return false if club_ids.empty?

      Club.where(id: club_ids).any? { |club| club.readable_by_game_operations?(go_ids) }
    end

    def scoped_licenses
      licenses = @player.licenses || []
      return licenses if params[:license_id].blank?

      licenses.select { |l| l['id'].to_s == params[:license_id].to_s }
    end

    def tm_for_player?
      ph = perm_hash
      return false if ph[:tm].blank?

      # Zwei Wege, beide zulaessig, aufgebaut wie `vm_for_player?` daneben:
      #
      # (a) Der TM verwaltet einen Verein, dem der Spieler HEUTE angehoert
      #     (`User#tm_club_ids`: die Vereine seiner Teams der laufenden Saison,
      #     SG-/Syndikats-Partner inbegriffen). Dieselbe Frage entscheidet ueber
      #     das Spielerprofil selbst (`PlayersController#tm_can_access_player?`)
      #     -- nicht wortgleich: Dort zaehlt zusaetzlich eine Zugehoerigkeit,
      #     die erst die Deaktivierung geschlossen hat
      #     (`membership_closed_by_deactivation?`), `player_active_club_ids`
      #     hier nicht. Bei einem deaktivierten Spieler bleibt der TM also am
      #     Profil drin und am Dokumentenblock draussen. Praktisch selten (die
      #     Vereinsliste filtert deaktivierte Profile heraus) und die
      #     vorsichtigere Richtung, deshalb bewusst so.
      # (b) Eine LAUFENDE Lizenz haengt an einem seiner Teams
      #     (`current_license_teams`).
      #
      # (a) ist neu und behebt einen Widerspruch: Der TM sah den Spieler in
      # „Meine Spieler*innen" (die Liste kommt vereinsweit aus `Club#players`),
      # durfte sein Profil oeffnen und die E-Mail-Adresse pflegen, bekam am
      # Dokumentenblock aber 403, solange keine Lizenz auf genau seinem Team lag.
      # Damit war der Upload zu Saisonbeginn unmoeglich, obwohl die Nachweise
      # (Anti-Doping-Erklaerung, Zustimmung der Erziehungsberechtigten)
      # Voraussetzung fuer den Lizenzantrag sind, und ebenso fuer jeden Spieler,
      # dessen Lizenz an einem anderen Team des Vereins haengt.
      #
      # (b) bleibt daneben stehen und ist nicht ueberfluessig: `all_club_ids`
      # nimmt `syndicate_clubs` nur bei gesetztem `syndicate`-Kennzeichen mit,
      # `player_in_team_clubs?` immer. Ein Team mit Partnervereinen ohne dieses
      # Kennzeichen faellt sonst aus (a) heraus.
      return true if (current_user.tm_club_ids & player_active_club_ids).present?

      tm_license_team_for_player?
    end

    # Weg (b) allein: eine LAUFENDE Lizenz an einem Team dieses TM. Das war die
    # ganze bisherige Regel und bleibt die Bedingung fuer das Loeschen (siehe
    # #check_delete_permission).
    def tm_license_team_for_player?
      ph = perm_hash
      return false if ph[:tm].blank?

      (ph[:tm] & current_license_teams.map(&:id)).present?
    end

    def vm_for_player?
      ph = perm_hash
      return false if ph[:vm].blank?

      # Der VM darf, wenn er (a) einen aktuell gültigen Verein des Spielers verwaltet
      # ODER (b) den Verein/Syndikat-Verein des Teams verwaltet, zu dem eine LAUFENDE
      # Lizenz gehört (`current_license_teams`: aktuelle Saison, Mitgliedschaft gilt
      # noch). (b) hält die Prüfung konsistent zu players#request_license
      # (SG-/Syndikats-Teams: der VM darf für einen Partnerclub-Spieler eine Lizenz
      # lösen und muss deren Dokumente sehen/verwalten können).
      return true if (ph[:vm] & player_active_club_ids).present?
      return true if (ph[:vm] & license_team_club_ids).present?

      false
    end

    # club_ids der aktuell gültigen Vereinsmitgliedschaften des Spielers.
    # Stichtag und Fehlerbehandlung kommen aus `LicenseAccessScope#membership_current?`,
    # dem Helfer, der auch über den Lizenzantrag entscheidet: Eine heute endende
    # Zugehörigkeit gilt noch, und ein unlesbares `valid_until` (Altbestand wie
    # "unbekannt" oder "0000-00-00") wird als Datenfehler gemeldet statt als 500
    # aus der Rechteprüfung geworfen. Vorher stand hier eine eigene Rechnung
    # (`to_time > Time.current`), die beides anders machte.
    def player_active_club_ids
      (@player.clubs || []).filter_map do |c|
        # Strukturell kaputter Eintrag: zählt nicht als Mitgliedschaft, wird aber
        # gemeldet statt still verworfen – wortgleich zu `player_in_team_clubs?`,
        # das im selben Request über dieselben Einträge läuft (der gemeinsame
        # Cache-Schlüssel drosselt die Meldung auf eine je Tag).
        unless c.is_a?(Hash)
          report_license_data_defect("player_clubs_entry_broken/#{@player.id}",
                                     "Spieler##{@player.id}: clubs-Eintrag ist kein Objekt (#{c.class})")
          next
        end
        next unless membership_current?(@player, c['valid_until'])

        c['club_id'].to_i
      end
    end

    # Teams, deren Lizenz dem Verein HEUTE noch Zugriff auf diesen Spieler gibt:
    # aus der laufenden Saison, und nur solange der Spieler in einem der
    # beteiligten Vereine dieses Teams noch Mitglied ist.
    #
    # Beide Einschränkungen fehlten. Damit genügte eine beliebig alte Lizenz eines
    # Teams seines Vereins, um dem VM (und über `tm_for_player?` dem TM) dauerhaft
    # Zugriff auf die persönlichen Unterlagen zu geben – Lesen, Hochladen und
    # Löschen –, auch Jahre nach dem Vereinswechsel.
    #
    # Am Spielerprofil greift seit #309 ebenfalls eine Gültigkeitsprüfung
    # (`PlayersController#membership_grants_access?`, auf demselben
    # `membership_current?`). Bis dahin genügte dort jeder Eintrag im clubs-Hash,
    # die Unterlagen waren also strenger als das Profil, an dem sie hängen.
    #
    # Deckungsgleich sind die beiden trotzdem nicht: Am Profil zählt zusätzlich
    # die Zugehörigkeit, die eine laufende Deaktivierung geschlossen hat, hier
    # nicht. Deaktiviert ein Verein seinen eigenen Spieler, behält er also das
    # Profil (sonst käme er nicht an `reactivate`) und verliert die Unterlagen.
    # Ohne laufende Lizenz gäbe es hier ohnehin nichts zu sehen.
    #
    # Die Mitgliedschaftsprüfung ist `player_in_team_clubs?`, also dieselbe wie im
    # Lizenzantrag: Wer für eine Mannschaft eine Lizenz lösen darf, soll deren
    # Dokumente sehen. Sie erhält den SG-/Syndikats-Fall, um den es (b) in
    # `vm_for_player?` überhaupt geht: Der Spieler gehört dem Partnerverein, das
    # Team dem anderen – dessen VM behält Zugriff, solange die Mitgliedschaft im
    # Partnerverein läuft.
    #
    # Ist `license_id` gesetzt, zählt nur diese Lizenz (index und create; `show`
    # adressiert das Dokument, nicht die Lizenz, und trägt den Wert nie).
    # Memoisiert wegen des doppelten Durchlaufs aus `check_read_permission` und der
    # Action selbst; jeder kostet sonst eine Team-Abfrage.
    def current_license_teams
      @current_license_teams ||= begin
        team_ids = scoped_licenses.filter_map { |l| l['team_id']&.to_i }.uniq
        if team_ids.empty?
          []
        else
          # `teams.league_id` ist nullable; seit #293 gibt es dort einen
          # Fremdschlüssel, der aber nur den Verweis ins Leere ausschließt (vgl.
          # TeamsController#render_team_without_league). Ein Team ohne Liga fällt
          # aus `Team.current_season` heraus, weil `NULL IN (…)` niemals wahr ist –
          # das ist ein Datenfehler und keine Rechteentscheidung. Deshalb erst
          # laden, dann melden, dann filtern: Sonst verliert der VM eines
          # Syndikats-Vereins den Zugriff, ohne dass die Ursache irgendwo auftaucht
          # (gleiche Regel wie `sbk_can_access_team?`).
          teams = Team.where(id: team_ids).includes(:league).to_a
          teams.each do |team|
            next if team.league.present?

            report_license_data_defect("license_team_without_league/#{team.id}",
                                       "Team##{team.id} (#{team.name}) ohne Liga, " \
                                       "league_id=#{team.league_id.inspect}")
          end

          teams.select { |team| current_season_team?(team) && player_in_team_clubs?(@player, team) }
        end
      end
    end

    def current_season_team?(team)
      team.league.present? && team.league.season_id.to_s == Setting.current_season_id.to_s
    end

    # club_ids (inkl. Syndikat) der Teams aus `current_license_teams`.
    def license_team_club_ids
      current_license_teams.flat_map(&:all_club_ids).uniq
    end

    def perm_hash
      @perm_hash ||= current_user.permission_hash
    end

    def admin?
      perm_hash[:admin].present?
    end

    # Archivierte Fassungen sieht nur der Verband (Admin oder SBK), nicht der
    # Verein. Ein gelöschter Nachweis soll aus der Vereinsablage verschwinden;
    # ohne diese Schranke holte der Verein ihn sich mit einem Abfrageparameter
    # zurück, und die Sperre gegen das Löschen archivierter Fassungen liefe ins
    # Leere. Welche Verbandsarten ein gescopter SBK dabei zu sehen bekommt,
    # entscheidet weiterhin filter_documents_by_scope.
    def verband?
      admin? || perm_hash[:sbk].present?
    end

    def include_archived?
      verband? && ActiveModel::Type::Boolean.new.cast(params[:include_archived])
    end

    # Erst die Zeile, dann die Datei: Scheitert `destroy!`, bliebe sonst ein
    # Datensatz ohne Anhang zurueck, den die Lizenzansichten als "fehlt" melden –
    # die Datei waere weg und die Zeile behauptete weiter, es gaebe sie. Gleiche
    # Reihenfolge wie beim Vorlagen-Austausch in DocumentTypesController#update.
    def purge_document(doc)
      warn_about_purged_proof(doc)
      doc.destroy!
      doc.file.purge
      render json: { success: true }
    end

    # Die Administration darf einen Nachweis endgueltig loeschen, etwa auf ein
    # Loeschverlangen nach Datenschutzrecht. Der Vorgang ist damit aber der eine
    # Weg, auf dem die Grundlage einer Erteilung doch verschwindet, und er soll
    # nicht geraeuschlos sein.
    def warn_about_purged_proof(doc)
      return unless relied_upon_by_approved_license?(doc)

      meldung = "Lizenzdokument ##{doc.id} (Spieler #{doc.player_id}, #{doc.document_type}) " \
                "endgueltig geloescht von Benutzer #{current_user.id}, obwohl eine erteilte " \
                'Lizenz darauf beruht'
      Rails.logger.warn(meldung)
      Sentry.capture_message(meldung) if defined?(Sentry)
    end

    # Beruht eine ERTEILTE Lizenz dieses Spielers auf dem Dokument? Dann ist es
    # der Nachweis einer Genehmigung und wird beim Löschen archiviert statt
    # vernichtet.
    #
    # Maßgeblich sind die Pflichtdokumente der Ligen, in denen der Spieler eine
    # erteilte Lizenz hat oder hatte, nach derselben Regel aufgelöst wie in den
    # Lizenzansichten (Altersgrenzen gegen das Antragsdatum, Elternzustimmung
    # zusätzlich über das Liga-Flag). Bewusst über ALLE Saisons: Auch eine
    # Lizenz von vor zwei Jahren wurde auf einer Unterlage erteilt.
    #
    # Bei per_season-Arten zählt nur die Fassung aus der Saison der Lizenz – ein
    # Upload aus einer anderen Saison war nie ihre Grundlage. Eine Fassung OHNE
    # Saison zählt dagegen mit: Die Spalte wurde erst am 08.07.2026 nachgerüstet
    # und nicht rückwirkend gefüllt, ihre Saison ist unbekannt und nicht "eine
    # andere". Ohne diese Ausnahme wäre gerade der Altbestand schutzlos, der die
    # meisten bereits erteilten Lizenzen trägt.
    #
    # Freiwillige Uploads, die keine Liga verlangt, bleiben ganz normal löschbar.
    def relied_upon_by_approved_license?(doc)
      # Lässt sich die Grundlage einer erteilten Lizenz nicht mehr ermitteln,
      # bleibt alles geschützt. Ein Nachweis darf nicht an einem Datenfehler
      # verloren gehen; gemeldet ist der Fehler beim Aufbau.
      return true if approved_license_basis[:unknown]

      per_season = DocumentType.find_by(key: doc.document_type)&.per_season?

      approved_license_basis[:requirements].any? do |req|
        req[:keys].include?(doc.document_type) &&
          (!per_season || doc.season_id.nil? || req[:season_id].to_s == doc.season_id.to_s)
      end
    end

    # { requirements: [{ keys:, season_id: }], unknown: <Grundlage unauflösbar?> }
    def approved_license_basis
      @approved_license_basis ||= build_approved_license_basis
    end

    def build_approved_license_basis
      licenses = Array(@player.licenses).select { |l| ever_approved?(l) }
      return { requirements: [], unknown: false } if licenses.empty?

      teams = Team.where(id: licenses.filter_map { |l| l['team_id'] }.uniq)
                  .includes(:league).index_by(&:id)
      unknown = false
      resolved = licenses.filter_map do |license|
        team = teams[license['team_id'].to_i]
        if team.nil? || team.league.nil?
          unknown = true
          report_license_data_defect(
            "approved_license_without_league/#{@player.id}",
            "Spieler##{@player.id}: erteilte Lizenz #{license['id'].inspect} ohne auflösbare " \
            "Mannschaft/Liga (team_id=#{license['team_id'].inspect})"
          )
          next
        end

        [license, team, team.season_leagues.flat_map { |l| league_required_document_keys(l) }.uniq]
      end

      { requirements: requirements_from(resolved), unknown: unknown }
    end

    # Den Katalog einmal für alle Ligaschlüssel laden: required_keys fragt ihn
    # sonst je Lizenz erneut ab.
    def requirements_from(resolved)
      catalog = document_type_catalog(resolved.flat_map { |(_, _, keys)| keys }.uniq)

      resolved.filter_map do |(license, team, league_keys)|
        next if league_keys.empty?

        { keys: resolved_required_keys(license, league_keys, catalog),
          season_id: team.league.season_id }
      end
    end

    # Ohne lesbares Antragsdatum bleiben ALLE Pflichtdokumente der Liga
    # geschützt. Die Altersgrenzen rechneten sonst gegen heute, und eine
    # inzwischen volljährige Person könnte die Elternzustimmung löschen, die
    # ihre Erteilung damals verlangt hat.
    def resolved_required_keys(license, league_keys, catalog)
      requested_at = license_requested_at(license)
      return league_keys if requested_at.nil?

      DocumentType.required_keys(league_keys, birthdate: @player.birthdate,
                                              requested_at: requested_at, catalog: catalog)
    end

    # War diese Lizenz jemals erteilt? Der AKTUELLE Status genügt nicht: Der
    # Verein setzt eine erteilte Lizenz über `reenable_license_request` ohne
    # Statusvorbedingung wieder auf "beantragt" und hätte danach freie Hand, den
    # Nachweis endgültig zu löschen. Fachlich ist "war erteilt" ohnehin das
    # richtige Kriterium: Eine später zurückgezogene, abgelaufene oder
    # korrigierte Lizenz WURDE auf dieser Unterlage erteilt, und genau das soll
    # belegbar bleiben.
    #
    # Der Verlauf wird dabei nur durchsucht, nicht sortiert – die Tücke des
    # Zeichenketten-Vergleichs der JSONB-Zeitstempel greift hier also nicht.
    def ever_approved?(license)
      Array(license['history']).any? { |h| h['license_status_id'].to_i == License::APPROVED }
    end

    # Katalog der referenzierten Dokumentarten, keyed per document_type-Key.
    # game_operation wird eager geladen, damit document_json/Scoping ohne N+1
    # auf Verband und Sichtbarkeit zugreifen können.
    def catalog_for(docs)
      keys = docs.map(&:document_type).uniq
      return {} if keys.empty?

      DocumentType.includes(:game_operation).where(key: keys).index_by(&:key)
    end

    # Sichtbarkeit richtet sich nach dem Katalog-Scope der Dokumentart:
    # Admin und global gescopter SBK (FD, ph[:sbk] enthält 0) sehen alles;
    # VM/TM-Zugriffe behalten Vollzugriff auf die Dokumente ihres Spielers. Ein
    # verbandsspezifisch gescopter SBK sieht nur globale Dokumentarten und die
    # seines/seiner Verbände.
    #
    # Rollen werden dabei additiv ausgewertet (gleiche Regel wie in
    # LicenseAccessScope#may_manage_team?): Wer für DIESEN Spieler VM oder TM
    # ist, verliert nichts dadurch, dass er zusätzlich irgendwo eine
    # verbandsgescopte SBK-Rolle hält. Vorher genügte ein einziger solcher
    # Eintrag, um einem VM die Dokumentarten seines EIGENEN Landesverbands aus
    # der Auswahl zu nehmen – hochladen konnte er sie dann nicht mehr.
    # Memoisiert, weil type_available? die Frage je Dokumentart stellt und der
    # VM/TM-Zweig sonst pro Art die Vereins- und Team-Prüfung erneut fährt
    # (license_team_club_ids kostet eine Team-Abfrage). defined? statt ||=, sonst
    # würde false jedes Mal neu berechnet.
    def unrestricted_document_access?
      return @unrestricted_document_access if defined?(@unrestricted_document_access)

      @unrestricted_document_access = compute_unrestricted_document_access
    end

    def compute_unrestricted_document_access
      return true if perm_hash[:admin].present?
      return true if perm_hash[:sbk].present? && perm_hash[:sbk].include?(0)
      return true if perm_hash[:sbk].blank?

      vm_for_player? || tm_for_player?
    end

    def filter_documents_by_scope(docs, catalog)
      return docs if unrestricted_document_access?

      sbk_go_ids = perm_hash[:sbk]
      docs.select { |doc| document_in_scope?(doc, catalog, sbk_go_ids) }
    end

    def document_visible?(doc)
      return true if unrestricted_document_access?

      document_in_scope?(doc, catalog_for([doc]), perm_hash[:sbk])
    end

    # Schreibseite, gleiche Regel wie die Leseseite (document_in_scope?) und wie
    # type_available? (b), nur ohne die Altersprüfung: Eine Art, deren Dokumente
    # der Aufrufer nicht zu sehen bekommt, darf er auch nicht befüllen – sonst
    # liegt der Upload danach unsichtbar für ihn in der Ablage. Die Oberfläche
    # bietet solche Arten ohnehin nicht an (available_types), durchgesetzt war
    # das aber nur dort.
    #
    # Freitext-Altbestand ohne Katalogeintrag bleibt erlaubt, ebenso wie er
    # sichtbar bleibt – document_in_scope? behandelt ihn genauso.
    def document_type_in_scope?(key)
      return true if unrestricted_document_access?

      go_id = DocumentType.find_by(key: key)&.game_operation_id
      go_id.nil? || perm_hash[:sbk].include?(go_id)
    end

    # Globale Dokumentarten (game_operation_id nil) und Freitext-Altbestand ohne
    # Katalogeintrag sind für alle sichtbar; verbandsspezifische nur für den
    # zuständigen Verband.
    def document_in_scope?(doc, catalog, sbk_go_ids)
      go_id = catalog[doc.document_type]&.game_operation_id
      return true if go_id.nil?

      sbk_go_ids.include?(go_id)
    end

    # Spielbetriebe, deren verbandsspezifische Dokumentarten für diesen Spieler in
    # Frage kommen: die HEIMAT-Spielbetriebe seiner aktuell gültigen Vereine.
    # Ligen bleiben bewusst außen vor (Entscheidung zu #383): Eine auf den
    # FD-Spielbetrieb gescopte Art erscheint hier also nicht bei einem
    # Bundesliga-Spieler aus einem Landesverbands-Verein. Im Lizenzantrag ist sie
    # weiterhin da, dort kommen die Pflichtdokumente aus league.required_documents.
    def player_home_game_operation_ids
      Club.where(id: player_active_club_ids)
          .map(&:main_game_operation_id)
          .compact
          .reject(&:zero?)
          .uniq
    end

    # Zwei Gründe, eine Art aus der Auswahl zu lassen:
    #
    # (a) Der Spieler ist ihr altersmäßig entwachsen: required_below_age
    #     überschritten oder ein Jahrgang vor required_from_birth_year. Ohne lesbares
    #     Geburtsdatum bleibt sie drin – required_for? entscheidet im Zweifel für
    #     "erforderlich", und dieselbe Regel gilt im Lizenzantrag.
    #     Beim Alter ist das endgültig, denn Alter steigt nur. Beim Jahrgang gilt es
    #     nur, solange die Zahl nach vorn gezogen wird: Senkt sie jemand, ist die Art
    #     für die älteren Jahrgänge wieder erforderlich. Das trägt, weil hier je
    #     Aufruf neu ausgewertet wird — eine gecachte Auswahl wäre falsch.
    # (b) Ein verbandsspezifisch gescopter SBK bekommt die Dokumente dieser Art
    #     ohnehin nicht zu sehen (filter_documents_by_scope). Dann darf die Art
    #     auch nicht in der Auswahl stehen, sonst lädt er in ein Loch hoch.
    def type_available?(document_type)
      return false unless document_type.required_for?(@player.birthdate, Time.current)
      return true if unrestricted_document_access?

      document_type.game_operation_id.nil? || perm_hash[:sbk].include?(document_type.game_operation_id)
    end

    def available_type_json(document_type)
      {
        id: document_type.id,
        key: document_type.key,
        name: document_type.name,
        description: document_type.description,
        validity: document_type.validity,
        required_below_age: document_type.required_below_age,
        required_from_birth_year: document_type.required_from_birth_year,
        game_operation_id: document_type.game_operation_id,
        game_operation_name: document_type.game_operation&.name,
        template_url: template_url_for(document_type)
      }
    end

    def template_url_for(document_type)
      return nil unless document_type.template.attached?

      rails_blob_url(document_type.template, disposition: 'attachment')
    end

    # Der Anhang kann fehlen (verlorener Blob, abgebrochener Upload). Vor der
    # Archivierung verschwand ein solcher Datensatz beim nächsten Upload, jetzt
    # überdauert er ihn – und `rails_blob_url(nil)` hätte die ganze Liste mit
    # einem Serverfehler beendet, dauerhaft und für jeden Aufruf. Gleiche Regel
    # wie in LicenseDocumentPresentation#document_map_for: ohne Datei keine
    # Adresse, dafür eine Spur im Protokoll.
    def document_json(doc, catalog = {})
      dt = catalog[doc.document_type]
      attached = doc.file.attached?
      unless attached
        Rails.logger.warn("LicenseDocument #{doc.id} (Spieler #{doc.player_id}, " \
                          "#{doc.document_type}) ohne Anhang – die Ablage weist ihn ohne Datei aus")
      end

      {
        id: doc.id,
        document_type: doc.document_type,
        document_type_name: dt&.name,
        validity: dt&.validity,
        game_operation_id: dt&.game_operation_id,
        game_operation_name: dt&.game_operation&.name,
        season_id: doc.season_id,
        filename: attached ? doc.file.filename.to_s : nil,
        content_type: attached ? doc.file.content_type : nil,
        byte_size: attached ? doc.file.byte_size : nil,
        created_at: doc.created_at,
        # Leer bei der aktuellen Fassung. Gesetzt heißt: abgelöst ('replaced')
        # oder gelöscht ('deleted'), als Nachweis aufbewahrt und weiterhin
        # abrufbar.
        archived_at: doc.archived_at&.iso8601,
        archived_reason: doc.archived_reason,
        archived_by: doc.archived_by&.full_with_username,
        url: attached ? rails_blob_url(doc.file, disposition: 'inline') : nil
      }
    end
  end
end
