class GameRefereeReportsController < ApplicationController
  before_action :authenticate_user
  before_action :set_game

  # GET /api/v2/games/:game_id/referee_report
  #
  # Nicht berechtigte Nutzer bekommen bewusst kein 403, sondern { uploaded: false }:
  # Die Spieldetailseite ruft diesen Endpoint für jeden eingeloggten Nutzer auf, und
  # ein 403 triggert im Frontend den globalen ErrorInterceptor (Popup + Redirect auf
  # "/"). Die Blob-URL selbst bleibt geschützt (nur Admin/SBK-im-Scope/angesetzte
  # Schiris sehen `uploaded: true` + `url`).
  #
  # `required` und `recipient` steuern den Upload-Bereich der Spielseite
  # (api#789): ob ein Bericht verlangt ist und an wen er nach dem Upload geht
  # ('vsk', 'sbk', 'vsk_and_sbk'). Das Frontend leitet das nicht mehr selbst
  # aus den Strafen ab. Beides nur für denselben Kreis wie die Datei, weil
  # `required` sonst verraten würde, dass ein besonderes Ereignis vermerkt ist.
  def show
    unless admin_or_sbk_for_game? || authorized_referee?
      return render json: { uploaded: false, required: false, recipient: nil }
    end

    recipient = @game.report_form_recipient
    result = { uploaded: false, required: recipient.present?, recipient: recipient }
    report = @game.game_referee_report
    if report&.file&.attached?
      result.merge!(
        uploaded: true,
        filename: report.file.filename.to_s,
        content_type: report.file.content_type,
        uploaded_at: report.created_at,
        url: rails_blob_url(report.file, disposition: 'inline')
      )
    end
    render json: result
  end

  # POST /api/v2/games/:game_id/referee_report
  def create
    unless authorized_referee?
      return render json: { message: 'Nur angesetzte Schiedsrichter können einen Bericht hochladen.' }, status: :forbidden
    end

    report = @game.game_referee_report || @game.build_game_referee_report(uploaded_by: current_user)
    report.uploaded_by = current_user
    report.file.attach(params[:file])

    if report.save
      _forward_report(report)
      render json: { success: true, filename: report.file.filename.to_s }, status: :created
    else
      render json: { errors: report.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def set_game
    @game = Game.find(params[:game_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Spiel nicht gefunden' }, status: :not_found
  end

  def admin_or_sbk_for_game?
    ph = current_user.permission_hash
    return true if ph[:admin].present?
    return false if ph[:sbk].blank?
    return true if ph[:sbk].include?(0)

    ph[:sbk].include?(@game.league.game_operation_id)
  end

  def authorized_referee?
    assignment = @game.referee_assignment
    return false unless assignment

    referee = current_user.referee
    return false unless referee

    [assignment.referee1_id, assignment.referee2_id].include?(referee.id)
  end

  # Wohin der Bericht geht, hängt an der Strafart (api#789):
  #
  #   Fall                        automatisch        manuell
  #   volle Matchstrafe           VSK                SBK + Verfahrensvorschlag
  #   techn. Matchstrafe          SBK                SBK
  #   besonderes Ereignis         SBK                SBK
  #   Mischfall                   VSK und SBK        SBK (alle Gründe) + Vorschlag
  #
  # Vorher ging jeder Bericht an die VSK, auch der zu einer technischen
  # Matchstrafe, die nie ein VSK-Verfahren nach sich zieht, und im manuellen
  # Modus entstand bei jedem Upload ein Verfahrensvorschlag, ohne dass die SBK
  # davon per Mail erfuhr.
  def _forward_report(report)
    # Maßgeblich ist der LV des Spielbetriebs, nicht der des Ausrichtervereins
    # (siehe Game#state_association). Schalter, Adressen und Verfahrensweg
    # kommen damit aus derselben Quelle.
    state_association = @game.state_association

    # report_form_email_enabled ist der Master-Schalter für den digitalen
    # Berichtsworkflow. Ist er aus, bleibt es beim analogen Vor-Ort-Prozess
    # (Papierbericht) – der Upload selbst löst dann nichts weiter aus.
    return unless state_association&.effective_report_form_email_enabled

    reasons = @game.report_form_reasons
    match_penalty = reasons.include?(:match_penalty)
    sbk_reasons = reasons - [:match_penalty]

    if state_association.effective_manual_proceeding_creation
      _forward_manually(report, state_association, reasons, match_penalty)
      return
    end

    _send_to_vsk(report, state_association) if match_penalty
    _send_to_sbk(report, state_association, sbk_reasons) if sbk_reasons.any?
  end

  # Manueller Modus: Nur eine Matchstrafe führt vor die VSK, und dann über den
  # Verfahrensvorschlag. Ein erneuter Upload richtet sich nach dessen Stand:
  #
  #   pending   bleibt offen, die SBK-Mail fordert erneut zur Eröffnung auf
  #   rejected  wird wieder offen (pending): neuer Bericht, neue Entscheidung
  #   opened    das Verfahren läuft, der neue Bericht geht direkt an die VSK,
  #             die SBK bekommt ihn nur zur Kenntnis
  def _forward_manually(report, state_association, reasons, match_penalty)
    proposal = _pending_or_opened_proposal(state_association) if match_penalty

    if proposal&.status == 'opened'
      _send_to_vsk(report, state_association)
      _send_to_sbk(report, state_association, reasons, proceeding: 'opened')
    else
      _send_to_sbk(report, state_association, reasons, proceeding: proposal && 'pending')
    end
  end

  def _send_to_vsk(report, state_association)
    vsk_email = state_association.effective_vsk_email
    return if vsk_email.blank?

    RefereeMailer.referee_report_to_vsk(
      vsk_email, current_user, @game, report,
      game_url: @game.url, checklist_answers: @game.checklist_answers || []
    ).deliver_later
  end

  def _send_to_sbk(report, state_association, reasons, proceeding: nil)
    return if reasons.empty?

    # Wie RefereeMailer#sbk_reply_to: Ohne SBK-Adresse (auch nicht geerbt)
    # landet der Bericht im Ansetzungs-Postfach statt nirgends. Gerade im
    # manuellen Modus wäre er sonst verloren, weil die VSK ihn nicht bekommt.
    sbk_email = state_association.effective_sbk_email.presence
    unless sbk_email
      Rails.logger.warn("GameRefereeReportsController: keine SBK-Adresse für LV #{state_association.id}, " \
                        "Berichtsformular zu Spiel #{@game.id} geht an #{RefereeMailer::REPLY_TO}")
      sbk_email = RefereeMailer::REPLY_TO
    end

    RefereeMailer.referee_report_to_sbk(
      sbk_email, current_user, @game, report,
      reasons: reasons, proceeding: proceeding,
      game_url: @game.url, checklist_answers: @game.checklist_answers || []
    ).deliver_later
  end

  # Ein abgelehnter Vorschlag wird bei einem neuen Bericht wieder offen; die
  # Entscheidung von damals galt dem verworfenen Bericht. Ein offener oder
  # eröffneter bleibt unverändert.
  def _pending_or_opened_proposal(state_association)
    proposal = ProceedingProposal.find_or_initialize_by(game_id: @game.id)
    return proposal unless proposal.new_record? || proposal.status == 'rejected'

    proposal.update!(state_association: state_association, status: 'pending',
                     created_by_id: current_user.id, decided_by_id: nil, decided_at: nil)
    proposal
  end
end
