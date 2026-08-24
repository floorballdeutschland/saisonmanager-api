module Admin
  class TransferRequestsController < ApplicationController
    before_action :authenticate_user
    before_action :authorize_transfer_access!
    skip_before_action :authenticate_user, only: %i[player_approve player_reject]
    skip_before_action :authorize_transfer_access!, only: %i[player_approve player_reject]

    def index
      ph = current_user.permission_hash
      requests = if ph[:admin].present?
        TransferRequest.all
      else
        # Rollen additiv auswerten statt per elsif-Kette: wer SBK *und* VM ist,
        # verlor sonst die Antraege des eigenen Vereins, sobald dieser
        # ausserhalb des SBK-Spielbetriebs liegt.
        scopes = []
        if ph[:sbk].present?
          club_ids = ph[:sbk].include?(0) ? Club.pluck(:id) : derive_club_ids_for_go(ph[:sbk])
          scopes << TransferRequest.where(former_club_id: club_ids)
        end
        if ph[:vm].present?
          scopes << TransferRequest.for_requesting_club(ph[:vm])
          scopes << TransferRequest.for_former_club(ph[:vm])
        end
        scopes.reduce { |combined, scope| combined.or(scope) } || TransferRequest.none
      end

      # Die Namen der beteiligten Konten einmal für die ganze Liste auflösen;
      # je Antrag einzeln wäre es eine Abfrage pro Zeile. Spieler und Vereine
      # aus demselben Grund vorladen: as_json liest je Zeile player_hash und
      # zweimal club_hash, das waren bisher drei Abfragen pro Antrag.
      records = requests.includes(:player, :requesting_club, :former_club)
                        .order(created_at: :desc).to_a
      actors = TransferRequest.actor_names_for(records)
      render json: records.map { |tr| tr.as_json(actors: actors) }
    end

    def search_player
      ph = current_user.permission_hash
      return render json: { error: 'Nicht berechtigt' }, status: :forbidden unless ph[:vm].present? || ph[:admin].present? || ph[:sbk].present?

      first_name = params[:first_name]&.strip
      last_name  = params[:last_name]&.strip
      birthdate  = params[:birthdate]&.strip

      if first_name.blank? || last_name.blank? || birthdate.blank?
        return render json: { error: 'Vorname, Nachname und Geburtsdatum sind erforderlich' }, status: :unprocessable_entity
      end

      begin
        birthdate = Date.iso8601(birthdate)
      rescue ArgumentError
        return render json: { error: 'Geburtsdatum muss im Format JJJJ-MM-TT übergeben werden' }, status: :unprocessable_entity
      end

      # Deaktivierte Profile gehoeren in dieses Ergebnis: Die Kennzeichnung gilt fuer
      # die Liste des abgebenden Vereins, nicht fuer die Aufnahme in einen neuen
      # (siehe `Player#deactivate!`). Zusammengefuehrte Dubletten bleiben draussen.
      # `with_exact_name` ignoriert Randleerzeichen auf beiden Seiten des
      # Vergleichs: Bestandsprofile mit einem Leerzeichen am Namensende
      # (api#496) faenden sonst nie einen exakten Treffer, obwohl das Formular
      # den eigenen Suchbegriff bereits trimmt (Zeilen 35-36).
      #
      # `.first` bleibt: Bei mehreren Treffern gewinnt die niedrigste ID, also
      # das aelteste Profil. Das ist die gewollte Auflösung -- die Dubletten aus
      # api#496 sind die spaeter angelegten.
      player = Player.where(merged_into_id: nil)
                     .with_exact_name(first_name, last_name, birthdate).first

      return render json: { player: nil } unless player

      requesting_club_id = params[:requesting_club_id].to_i
      if ph[:vm].present? && !may_act_for_club?(ph, requesting_club_id)
        return render json: { error: 'Nicht berechtigt fuer diesen Verein' }, status: :forbidden
      end

      if requesting_club_id > 0
      # Dieselbe Auskunft wie in create, sonst meldet die Suche einen Treffer und
      # der Antrag faellt gleich danach auf 422 (api#512).
      if Club.find_by(id: requesting_club_id)&.deactivated_at.present?
        return deactivated_requesting_club_response
      end

      # Derselbe Leser wie in create/direct_assign -- sonst faellt die Suche gegen den
      # ersten offenen Heimat-Eintrag und der Antrag gleich danach gegen den letzten,
      # und die Suche weist einen Antrag ab, den create zugelassen haette.
      home_club = player.home_club_entry
      if home_club&.dig('club_id') == requesting_club_id
        return render json: { error: 'Spieler ist bereits in diesem Verein' }, status: :unprocessable_entity
      end
      end

      if TransferRequest.active.where(player_id: player.id).exists?
        return render json: { error: 'Fuer diesen Spieler ist bereits ein Transferantrag aktiv' }, status: :unprocessable_entity
      end

      render json: { player: player.search_hash }
    end

    def show
      tr = find_transfer_request
      return unless tr

      unless transfer_visible?(tr)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      render json: tr.as_json
    end

    def create
      ph = current_user.permission_hash
      return render json: { error: 'Nicht berechtigt' }, status: :forbidden unless ph[:vm].present? || ph[:admin].present?

      player = Player.find_by(id: params[:player_id])
      return render json: { error: 'Spieler nicht gefunden' }, status: :not_found unless player

      return merged_player_response if player.merged_into_id.present?

      # Ohne E-Mail-Adresse kann der Spieler den Transfer später nicht bestätigen,
      # daher den Antrag gar nicht erst starten (gleiche Meldung wie in approve_club).
      unless player.email.present?
        return render json: {
          error: 'Für das Spielerprofil ist keine E-Mailadresse hinterlegt. Bitte den aktuellen Verein oder die zuständige SBK kontaktieren.'
        }, status: :unprocessable_entity
      end

      requesting_club_id = params[:requesting_club_id].to_i
      if ph[:vm].present? && !may_act_for_club?(ph, requesting_club_id)
        return render json: { error: 'Nicht berechtigt fuer diesen Verein' }, status: :forbidden
      end

      requesting_club = Club.find_by(id: requesting_club_id)
      return render json: { error: 'Verein nicht gefunden' }, status: :not_found unless requesting_club
      return deactivated_requesting_club_response if requesting_club.deactivated_at.present?

      if TransferRequest.active.where(player_id: player.id).exists?
        return render json: { error: 'Fuer diesen Spieler ist bereits ein Transferantrag aktiv' }, status: :unprocessable_entity
      end

      # Player#home_club_entry ist die eine Quelle: Diese Stelle las frueher den ERSTEN
      # offenen Heimat-Eintrag, waehrend Player#home_club den LETZTEN nimmt. Bei zwei
      # offenen Eintraegen meinten beide verschiedene Vereine, und der Antrag ging an den
      # falschen abgebenden Verein zur Genehmigung.
      former_club_id = player.home_club_entry&.dig('club_id')
      return render json: { error: 'Spieler hat keinen aktiven Heimverein' }, status: :unprocessable_entity unless former_club_id

      if former_club_id == requesting_club_id
        return render json: { error: 'Spieler ist bereits in diesem Verein' }, status: :unprocessable_entity
      end

      former_club = Club.find_by(id: former_club_id)
      return render json: { error: 'Abgebender Verein nicht gefunden' }, status: :not_found unless former_club

      request_type = params[:request_type].to_s == 'release' ? 'release' : 'transfer'

      # Transfersperrfrist: nach einem erfolgreich abgeschlossenen Transfer ist
      # für den Spieler TRANSFER_LOCK_PERIOD lang kein neuer Transferantrag
      # möglich. Maßgeblich ist der tatsächliche Abschlusszeitpunkt
      # (Transfer.created_at), nicht das LV-Genehmigungsdatum – relevant bei
      # geplanten Transfers mit Wunschdatum. Freigaben sind nicht betroffen.
      if request_type == 'transfer'
        last_transfer = Transfer.where(player_id: player.id)
                                .where('created_at > ?', TransferRequest::TRANSFER_LOCK_PERIOD.ago)
                                .order(created_at: :desc)
                                .first
        if last_transfer
          lock_until = last_transfer.created_at + TransferRequest::TRANSFER_LOCK_PERIOD
          return render json: {
            error: "Für diesen Spieler wurde am #{last_transfer.created_at.strftime('%d.%m.%Y')} ein Transfer " \
                   "abgeschlossen. Ein neuer Transferantrag ist erst ab dem #{lock_until.strftime('%d.%m.%Y')} möglich " \
                   '(Transfersperrfrist von 4 Wochen).'
          }, status: :unprocessable_entity
        end
      end

      effective_date = nil
      if request_type == 'transfer' && params[:effective_date].present?
        begin
          effective_date = Date.parse(params[:effective_date].to_s)
          if effective_date < Date.today + 7
            return render json: { error: 'Wunschdatum muss mindestens 7 Tage in der Zukunft liegen' }, status: :unprocessable_entity
          end
        rescue ArgumentError
          return render json: { error: 'Ungültiges Datum' }, status: :unprocessable_entity
        end
      end

      tr = TransferRequest.new(
        player_id: player.id,
        requesting_club_id: requesting_club_id,
        former_club_id: former_club_id,
        status: 'pending_club',
        created_by: current_user.id,
        season_id: Setting.current_season_id,
        effective_date:,
        request_type:
      )

      if tr.save
        TransferRequestMailer.new_request_to_former_club(tr).deliver_later
        render json: tr.as_json, status: :created
      else
        render json: { errors: tr.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def approve_club
      tr = find_transfer_request
      return unless tr

      unless tr.status == 'pending_club'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:vm]&.include?(tr.former_club_id)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      # Auch mitten in der Kette: Sonst arbeitet der abgebende Verein einen
      # Antrag ab, der bei approve_lv garantiert abgewiesen wird, und der
      # Spieler bekommt eine Bestaetigungsmail dafuer.
      return deactivated_requesting_club_response if tr.requesting_club.deactivated_at.present?

      unless tr.player.email.present?
        return render json: {
          error: 'Für das Spielerprofil ist keine E-Mailadresse hinterlegt. Bitte den aktuellen Verein oder die zuständige SBK kontaktieren.'
        }, status: :unprocessable_entity
      end

      tr.update!(
        status: 'pending_player',
        approved_by_club_user_id: current_user.id,
        club_approved_at: Time.current
      )

      TransferRequestMailer.player_confirmation_request(tr).deliver_later

      render json: tr.as_json
    end

    def reject_club
      tr = find_transfer_request
      return unless tr

      unless tr.status == 'pending_club'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:vm]&.include?(tr.former_club_id)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      reason = params[:rejection_reason]&.strip
      if reason.blank?
        return render json: { error: 'Begruendung ist erforderlich' }, status: :unprocessable_entity
      end

      tr.update!(
        status: 'rejected_by_club',
        rejected_by: current_user.id,
        rejected_at: Time.current,
        rejection_reason: reason,
        player_confirmation_token: nil
      )

      TransferRequestMailer.rejected_notification(tr).deliver_later
      render json: tr.as_json
    end

    def approve_lv
      tr = find_transfer_request
      return unless tr

      unless tr.status == 'pending_lv'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || lv_authorized?(ph, tr)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      return merged_player_response if tr.player.merged_into_id.present?

      # Auch die Freigabe legt eine Mitgliedschaft im aufnehmenden Verein an
      # (execute_release! über add_secondary_club_membership!), der Riegel sitzt
      # deshalb vor der Verzweigung.
      return deactivated_requesting_club_response if tr.requesting_club.deactivated_at.present?

      if tr.request_type == 'release'
        tr.execute_release!(current_user.id)
      elsif tr.effective_date.nil? || tr.effective_date <= Date.today
        tr.execute_transfer!(current_user.id)
      else
        tr.update!(
          status: 'scheduled',
          approved_by_lv_user_id: current_user.id,
          lv_approved_at: Time.current
        )
      end

      render json: tr.as_json
    end

    def revoke
      tr = find_transfer_request
      return unless tr

      unless tr.request_type == 'release'
        return render json: { error: 'Nur Freigaben koennen zurueckgezogen werden' }, status: :unprocessable_entity
      end

      unless tr.status == 'approved'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || lv_authorized?(ph, tr)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      reason = params[:revocation_reason]&.strip
      if reason.blank?
        return render json: { error: 'Begruendung ist erforderlich' }, status: :unprocessable_entity
      end

      tr.revoke_release!(current_user.id, reason)
      render json: tr.as_json
    end

    def execute
      tr = find_transfer_request
      return unless tr

      unless tr.status == 'scheduled'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || lv_authorized?(ph, tr)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      if tr.effective_date.present? && tr.effective_date > Date.today
        return render json: { error: "Transfer wird erst am #{tr.effective_date.strftime('%d.%m.%Y')} wirksam" }, status: :unprocessable_entity
      end

      return merged_player_response if tr.player.merged_into_id.present?
      return deactivated_requesting_club_response if tr.requesting_club.deactivated_at.present?

      tr.execute_transfer!(current_user.id)
      render json: tr.as_json
    end

    def reject_lv
      tr = find_transfer_request
      return unless tr

      unless tr.status == 'pending_lv'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || lv_authorized?(ph, tr)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      reason = params[:rejection_reason]&.strip
      if reason.blank?
        return render json: { error: 'Begruendung ist erforderlich' }, status: :unprocessable_entity
      end

      tr.update!(
        status: 'rejected_by_lv',
        rejected_by: current_user.id,
        rejected_at: Time.current,
        rejection_reason: reason,
        player_confirmation_token: nil
      )

      TransferRequestMailer.rejected_notification(tr).deliver_later
      render json: tr.as_json
    end

    def withdraw
      tr = find_transfer_request
      return unless tr

      unless %w[pending_club pending_player pending_lv].include?(tr.status)
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:vm]&.include?(tr.requesting_club_id)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      tr.update!(status: 'withdrawn', withdrawn_by: current_user.id, withdrawn_at: Time.current,
                 player_confirmation_token: nil)
      render json: tr.as_json
    end

    def player_approve
      tr = TransferRequest.find_by(player_confirmation_token: params[:token])
      base_url = "#{FrontendUrl.base}/transfer-bestaetigung"

      unless tr
        return redirect_to "#{base_url}?result=error", allow_other_host: true
      end

      unless tr.status == 'pending_player'
        result = tr.status.in?(%w[pending_lv scheduled approved]) ? 'already_approved' : 'error'
        return redirect_to "#{base_url}?result=#{result}", allow_other_host: true
      end

      tr.update!(status: 'pending_lv', player_approved_at: Time.current)

      TransferRequestMailer.pending_lv_notification(tr).deliver_later
      TransferRequestMailer.clubs_informed_lv_pending(tr).deliver_later

      redirect_to "#{base_url}?result=approved", allow_other_host: true
    end

    def player_reject
      tr = TransferRequest.find_by(player_confirmation_token: params[:token])
      base_url = "#{FrontendUrl.base}/transfer-bestaetigung"

      unless tr
        return redirect_to "#{base_url}?result=error", allow_other_host: true
      end

      unless tr.status == 'pending_player'
        result = tr.status == 'rejected_by_player' ? 'already_rejected' : 'error'
        return redirect_to "#{base_url}?result=#{result}", allow_other_host: true
      end

      tr.update!(status: 'rejected_by_player', player_rejected_at: Time.current, player_confirmation_token: nil)

      TransferRequestMailer.player_rejected_clubs_notification(tr).deliver_later

      redirect_to "#{base_url}?result=rejected", allow_other_host: true
    end

    # POST /api/v2/admin/transfer_requests/direct_assign
    # SBK/Admin weist einen Spieler direkt einem anderen Verein zu (ohne den
    # mehrstufigen Genehmigungsprozess). Es entsteht ein TransferRequest
    # (direct: true), der sofort vollzogen wird und in der Liste erscheint.
    def direct_assign
      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:sbk].present?
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      player = Player.find_by(id: params[:player_id])
      return render json: { error: 'Spieler nicht gefunden' }, status: :not_found unless player

      return merged_player_response if player.merged_into_id.present?

      requesting_club = Club.find_by(id: params[:requesting_club_id].to_i)
      return render json: { error: 'Verein nicht gefunden' }, status: :not_found unless requesting_club

      return deactivated_requesting_club_response if requesting_club.deactivated_at.present?

      # Player#home_club_entry ist die eine Quelle: Diese Stelle las frueher den ERSTEN
      # offenen Heimat-Eintrag, waehrend Player#home_club den LETZTEN nimmt. Bei zwei
      # offenen Eintraegen meinten beide verschiedene Vereine, und der Antrag ging an den
      # falschen abgebenden Verein zur Genehmigung.
      former_club_id = player.home_club_entry&.dig('club_id')
      return render json: { error: 'Spieler hat keinen aktiven Heimverein' }, status: :unprocessable_entity unless former_club_id

      former_club = Club.find_by(id: former_club_id)
      return render json: { error: 'Abgebender Verein nicht gefunden' }, status: :not_found unless former_club

      if former_club_id == requesting_club.id
        return render json: { error: 'Spieler ist bereits in diesem Verein' }, status: :unprocessable_entity
      end

      unless sbk_may_assign?(ph, former_club, requesting_club)
        return render json: { error: 'Nicht berechtigt (abgebender Verein liegt außerhalb des eigenen Landesverbands).' },
                      status: :forbidden
      end

      if TransferRequest.active.where(player_id: player.id).exists?
        return render json: { error: 'Für diesen Spieler ist bereits ein Transfer aktiv. Bitte zuerst annullieren.' },
                      status: :unprocessable_entity
      end

      tr = nil
      # create! und execute_transfer! atomar klammern: andernfalls bleibt die
      # committete pending_lv-Zeile stehen, wenn execute_transfer! danach noch
      # scheitert, und blockiert via active-Guard jeden Retry.
      TransferRequest.transaction do
        tr = TransferRequest.create!(
          player_id: player.id,
          requesting_club_id: requesting_club.id,
          former_club_id: former_club_id,
          status: 'pending_lv',
          direct: true,
          created_by: current_user.id,
          season_id: Setting.current_season_id,
          request_type: 'transfer'
        )
        tr.execute_transfer!(current_user.id)
      end

      render json: tr.as_json, status: :created
    rescue ActiveRecord::RecordNotUnique
      render json: { error: 'Für diesen Spieler ist bereits ein Transfer aktiv. Bitte zuerst annullieren.' },
             status: :unprocessable_entity
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # PATCH /api/v2/admin/transfer_requests/:id/cancel
    # SBK/Admin annulliert einen laufenden (noch nicht abgeschlossenen) Transfer.
    def cancel
      tr = find_transfer_request
      return unless tr

      unless %w[pending_club pending_player pending_lv scheduled].include?(tr.status)
        return render json: { error: 'Nur laufende Transfers können annulliert werden' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || lv_authorized?(ph, tr)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      tr.update!(status: 'withdrawn', withdrawn_by: current_user.id, withdrawn_at: Time.current,
                 player_confirmation_token: nil)
      render json: tr.as_json
    end

    private

    # Nicht `deactivated_at`: Eine Deaktivierung ist die Kennzeichnung des
    # abgebenden Vereins und kein Transferhindernis. Eine zusammengefuehrte
    # Dublette dagegen ist durch den Master ersetzt.
    #
    # Geprüft nicht nur beim Anlegen, sondern auch beim Genehmigen und
    # Vollziehen (api#486): Der Merge kann mitten im Verfahren passieren, und
    # seit `clear_deactivation` die Kennzeichnung stehen lässt, entwertete
    # `execute_transfer!` sonst die Lizenzen des abgebenden Vereins und schriebe
    # eine Zugehörigkeit, die niemand mehr zu sehen bekommt.
    def merged_player_response
      render json: { error: 'Dieses Profil wurde mit einem anderen zusammengeführt und kann nicht transferiert werden' },
             status: :unprocessable_entity
    end

    # Der abgebende Verein darf deaktiviert sein (ein aufgelöster Verein gibt
    # seine Spieler ja gerade ab), der aufnehmende nicht: Er soll keine neuen
    # Mitglieder mehr bekommen. Die Auswahlmaske bietet ihn nicht an, ein
    # direkter Aufruf käme sonst aber durch.
    #
    # Geprüft an jedem Schritt, weil der mehrstufige Prozess über Tage läuft und
    # die Deaktivierung dazwischen fallen kann (api#512): bei der Suche und beim
    # Anlegen, damit der Antrag gar nicht erst entsteht, bei der Vereinsfreigabe,
    # damit niemand einen aussichtslosen Antrag abarbeitet, und beim Genehmigen
    # und Vollziehen, damit sie in jedem Fall greift. Die Direktzuweisung nutzt
    # dieselbe Meldung, damit es eine Begründung bleibt.
    #
    # Nicht geprüft wird in #player_approve: Der Spieler bestätigt dort über
    # einen Mail-Link ohne Anmeldung, und die Aktion antwortet mit einem
    # Redirect, nicht mit JSON. Der Riegel bei #approve_lv greift danach.
    #
    # Bewusst hier und nicht in TransferRequest#execute_transfer!: Ein `raise`
    # dort wäre die eine Quelle, ließe #approve_lv und #execute aber in einen
    # 500 laufen, weil nur #direct_assign ein `rescue ActiveRecord::RecordInvalid`
    # hat.
    def deactivated_requesting_club_response
      render json: { error: 'Der aufnehmende Verein ist deaktiviert' }, status: :unprocessable_entity
    end

    # Darf der Nutzer für diesen Verein handeln? Stärkere Rollen gehen der
    # VM-Vereinsbindung vor: wer neben der VM-Rolle auch Admin oder SBK ist,
    # wurde sonst von der eigenen schwächeren Rolle ausgesperrt (SBK + VM kam
    # so nie bis zum Direkt-Transfer, obwohl #direct_assign es erlaubt hätte).
    def may_act_for_club?(ph, club_id)
      return true if ph[:admin].present?
      return true if ph[:vm].present? && ph[:vm].include?(club_id)
      return false if ph[:sbk].blank?
      return true if ph[:sbk].include?(0)

      club = Club.find_by(id: club_id)
      club.present? && ph[:sbk].include?(club.main_game_operation_id)
    end

    # Für die Freigabe zählt wie bei #lv_authorized? nur der Landesverband des
    # abgebenden Vereins (der verliert das Mitglied und muss zustimmen); der
    # aufnehmende Verein kann in jedem anderen Landesverband liegen. Global
    # gescopte SBK (FD) und Admin dürfen ohnehin verbandsübergreifend.
    def sbk_may_assign?(ph, former_club, _requesting_club)
      return true if ph[:admin].present?
      return false unless ph[:sbk].present?
      return true if ph[:sbk].include?(0)

      ph[:sbk].include?(former_club.main_game_operation_id)
    end

    def authorize_transfer_access!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Einzelabruf spiegelt exakt die Sichtbarkeit aus #index: Admin sieht alles,
    # SBK die Anträge der Vereine im eigenen Spielbetrieb, VM nur Anträge des
    # eigenen (abgebenden oder aufnehmenden) Vereins.
    def transfer_visible?(tr)
      ph = current_user.permission_hash
      return true if ph[:admin].present?

      if ph[:sbk].present?
        return true if ph[:sbk].include?(0)
        return true if derive_club_ids_for_go(ph[:sbk]).include?(tr.former_club_id)
      end

      if ph[:vm].present?
        return true if ph[:vm].include?(tr.requesting_club_id) || ph[:vm].include?(tr.former_club_id)
      end

      false
    end

    def find_transfer_request
      tr = TransferRequest.find_by(id: params[:id])
      render json: { error: 'Nicht gefunden' }, status: :not_found unless tr
      tr
    end

    def lv_authorized?(ph, tr)
      return false unless ph[:sbk].present?
      return true if ph[:sbk].include?(0)

      ph[:sbk].include?(tr.former_club.main_game_operation_id)
    end

    def derive_club_ids_for_go(go_ids)
      Club.home_clubs_of(go_ids).pluck(:id)
    end
  end
end
