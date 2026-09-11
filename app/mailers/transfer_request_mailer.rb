class TransferRequestMailer < ApplicationMailer
  # Absichtlich ohne den Spieler als Empfaenger: der Text richtet sich an den
  # abgebenden Verein und verlinkt in die Verwaltung, wofuer Spieler keinen
  # Zugang haben. Der Spieler wird erst mit #player_confirmation_request
  # angeschrieben, also wenn er selbst zustimmen oder ablehnen kann.
  def new_request_to_former_club(transfer_request)
    @transfer_request = transfer_request
    recipients = transfer_request.former_club.notification_emails.compact.uniq.select(&:present?)
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "Neue#{release?(transfer_request) ? ' Spielerfreigabe-Anfrage' : ' Transferanfrage'}: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: release?(transfer_request) ? 'Spielerfreigabe-Anfrage' : 'Transferanfrage',
        player_name: player_name(transfer_request)
      }
    )
  end

  # Empfaenger ist die Postfachkette des abgebenden Vereins (eigenes Postfach,
  # sonst das des Verbunds). BENANNT wird im Text dagegen der zustaendige
  # Verband (Club#responsible_state_association), denn genehmigen darf nur der.
  # Beides faellt nur auseinander, wenn ein Kind-LV ein eigenes Postfach
  # pflegt: Dann liest es die Mail, entscheiden tut weiterhin der Verbund.
  def pending_lv_notification(transfer_request)
    @transfer_request = transfer_request
    sbk_email = transfer_request.former_club.state_association&.effective_sbk_email
    return unless sbk_email.present?

    templated_mail(
      to: sbk_email,
      subject: "#{request_noun(transfer_request)} zur Genehmigung: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: request_noun(transfer_request),
        player_name: player_name(transfer_request)
      }
    )
  end

  def clubs_informed_lv_pending(transfer_request)
    @transfer_request = transfer_request
    recipients = (
      transfer_request.requesting_club.notification_emails +
      transfer_request.former_club.notification_emails +
      [transfer_request.player.email]
    ).compact.uniq.select(&:present?)
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "#{request_noun(transfer_request)} liegt beim Landesverband: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: request_noun(transfer_request),
        player_name: player_name(transfer_request)
      }
    )
  end

  def rejected_notification(transfer_request)
    @transfer_request = transfer_request
    recipients = transfer_request.requesting_club.notification_emails
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "#{request_noun(transfer_request)} abgelehnt: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: request_noun(transfer_request),
        player_name: player_name(transfer_request)
      }
    )
  end

  def player_confirmation_request(transfer_request)
    @transfer_request = transfer_request
    recipient = transfer_request.player.email
    return unless recipient.present?

    subject_prefix = release?(transfer_request) ? 'Spielerfreigabe-Anfrage' : 'Transferanfrage'
    templated_mail(
      to: recipient,
      subject: "#{subject_prefix}: Deine Zustimmung wird benoetigt - #{player_name(transfer_request)}",
      placeholders: {
        request_noun: subject_prefix,
        player_name: player_name(transfer_request)
      }
    )
  end

  # Der aufnehmende Verein wurde deaktiviert, der Antrag ist damit beendet
  # (api#528). Empfaenger sind der Spieler und der abgebende Verein: Der Spieler
  # hat unter Umstaenden schon zugestimmt und wartet, der abgebende Verein
  # behaelt ihn nun doch. Der aufnehmende Verein bekommt bewusst keine Mail, sein
  # Postfach ist bei einem aufgeloesten Verein selten noch besetzt, und die
  # Deaktivierung kam von seiner Seite.
  def club_deactivated_notification(transfer_request)
    @transfer_request = transfer_request
    recipients = ([transfer_request.player.email] +
                  transfer_request.former_club.notification_emails)
                 .map { |mail| mail.to_s.strip }.reject(&:blank?).uniq
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "#{request_noun(transfer_request)} beendet, Verein deaktiviert: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: request_noun(transfer_request),
        player_name: player_name(transfer_request),
        club_name: transfer_request.requesting_club.name
      }
    )
  end

  def player_rejected_clubs_notification(transfer_request)
    @transfer_request = transfer_request
    recipients = (
      transfer_request.requesting_club.notification_emails +
      transfer_request.former_club.notification_emails
    ).compact.uniq.select(&:present?)
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "#{request_noun(transfer_request)} abgelehnt durch Spieler: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: request_noun(transfer_request),
        player_name: player_name(transfer_request)
      }
    )
  end

  # Der Transfer ist vollstaendig genehmigt, wird aber erst zum Wunschdatum
  # vollzogen (`approve_lv` mit einem Datum in der Zukunft). Bis hierher war das
  # der zweite stumme Weg nach „Genehmigt": Der Vorgang stand in der Uebersicht
  # auf „Transfer geplant", im Detail auf „Genehmigt -- Transfer geplant", und
  # niemand erfuhr davon. Beide Vereine planen ihre Mannschaften an diesem
  # Datum, und der abgebende Verein verliert den Spieler zu einem Termin, den
  # er nicht mitgeteilt bekam.
  #
  # Verteiler wie #transfer_completed: Diese Nachricht kuendigt genau die an.
  # Der Landesverband des abgebenden Vereins ist dabei zugleich der, der gerade
  # genehmigt hat -- er bleibt trotzdem im Verteiler, denn den Vollzug muss
  # jemand von Hand ausloesen (siehe unten), und sein Postfach ist der Kanal,
  # ueber den die Landesverbaende die Vorgaenge nachhalten.
  #
  # Die Nachricht behauptet ausdruecklich KEINEN automatischen Vollzug: Es gibt
  # keinen Job, der `execute_transfer!` zum Wunschdatum ausloest -- aufgerufen
  # wird es allein aus `approve_lv`, `#execute` und `#direct_assign`. Ein
  # geplanter Transfer wartet auf den Knopf in der Maske.
  def transfer_scheduled(transfer_request)
    @transfer_request = transfer_request
    former_sa = transfer_request.former_club.state_association
    recipients = (
      transfer_request.requesting_club.notification_emails +
      transfer_request.former_club.notification_emails +
      [transfer_request.player.email, former_sa&.effective_sbk_email]
    ).compact.uniq.select(&:present?)
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "Transfer genehmigt, Vollzug am #{effective_date(transfer_request)}: #{player_name(transfer_request)}",
      placeholders: {
        player_name: player_name(transfer_request),
        effective_date: effective_date(transfer_request)
      }
    )
  end

  def transfer_completed(transfer_request)
    @transfer_request = transfer_request
    former_sa = transfer_request.former_club.state_association
    recipients = (
      transfer_request.requesting_club.notification_emails +
      transfer_request.former_club.notification_emails +
      [transfer_request.player.email, former_sa&.effective_sbk_email]
    ).compact.uniq.select(&:present?)
    return if recipients.empty?

    subject = release?(transfer_request) ? 'Spielerfreigabe erteilt' : 'Transfer vollzogen'
    templated_mail(
      to: recipients,
      subject: "#{subject}: #{player_name(transfer_request)}",
      placeholders: {
        completion_noun: subject,
        player_name: player_name(transfer_request)
      }
    )
  end

  # Widerruf einer bereits ERTEILTEN Freigabe (#640). Nur dieser Fall ist
  # gemeint: `revoke` laesst nur `request_type` "release" mit Status "approved"
  # zu, ein noch laufender Antrag wird zurueckgezogen und nicht widerrufen.
  #
  # Empfaenger sind die Seiten, die den Widerruf NICHT veranlasst haben und von
  # ihm betroffen sind: der Verein, der den Spieler jetzt nicht mehr einsetzen
  # darf, sein Landesverband, der Heimverein und der Spieler selbst. Der
  # abgebende Landesverband hat ihn ausgeloest und bekommt keine.
  #
  # Der aufnehmende Landesverband ist der eigentliche Grund fuer diese Mail: Bis
  # hierher erfuhr er von einem Widerruf ueber keinen Kanal.
  #
  # In der Uebersicht "Eingehende Transfers & Freigaben" steht ein widerrufener
  # Vorgang inzwischen (siehe INCOMING_STATUSES) -- die Mail ist damit nicht
  # ueberfluessig geworden, sondern bleibt der einzige Kanal, der nicht am
  # Saisonfilter haengt: Wird eine Freigabe der Vorsaison nach dem
  # Saisonwechsel widerrufen, ist die Zeile standardmaessig aus beiden Listen
  # heraus, und die Zweitmitgliedschaft endet trotzdem.
  #
  # Die Begruendung reist mit: Sie ist beim Widerruf Pflicht (siehe #revoke),
  # und ohne sie ist die Nachricht fuer den Empfaenger nicht einzuordnen.
  # `licenses_invalidated` unterscheidet die beiden Widerrufswege: Ueber den
  # Vorgang (#revoke_release!) werden die Lizenzen des aufnehmenden Vereins
  # mit entwertet, ueber das Spielerprofil
  # (PlayerReleaseRecording#save_with_release_revocation) bewusst nicht -- dort
  # wird nur mitgeschrieben, was der Knopf ohnehin tut. Die Nachricht darf
  # nichts behaupten, was nicht passiert ist; die beendete Zweitmitgliedschaft
  # ist beiden Wegen gemeinsam und der Grund fuer die Mail.
  def release_revoked(transfer_request, licenses_invalidated: true)
    @transfer_request = transfer_request
    @licenses_invalidated = licenses_invalidated
    receiving_sa = transfer_request.requesting_club.state_association
    recipients = (
      transfer_request.requesting_club.notification_emails +
      transfer_request.former_club.notification_emails +
      [transfer_request.player.email, receiving_sa&.effective_sbk_email]
    ).compact.uniq.select(&:present?)

    # Nicht stumm zurueckkehren wie die uebrigen Mails dieser Datei: Bei keiner
    # von ihnen ist die Folge, dass ein Verein einen nicht mehr
    # spielberechtigten Spieler aufstellt. Ein leerer Verteiler heisst hier,
    # dass der Widerruf ueber keinen einzigen Kanal ankommt -- und der Vorgang
    # faellt aus beiden Listen, sobald er aus der laufenden Saison heraus ist.
    # Gleiches Muster wie PlayerMailer#express_license_requested.
    if recipients.empty?
      if defined?(Sentry)
        Sentry.capture_message(
          "Widerruf ohne Empfaenger: TransferRequest##{transfer_request.id} -- " \
          'weder Vereine noch Landesverband noch Spieler haben eine Adresse.'
        )
      end
      return
    end

    templated_mail(
      to: recipients,
      subject: "Spielerfreigabe zurueckgezogen: #{player_name(transfer_request)}",
      placeholders: {
        player_name: player_name(transfer_request),
        revocation_reason: transfer_request.revocation_reason.to_s
      }
    )
  end

  # Ein laufender Freigabeantrag ist mit dem Vollzug eines Transfers beendet
  # (siehe TransferRequest#annul_pending_releases!). Empfaenger sind der Verein,
  # der die Freigabe wollte, und der Spieler selbst: Beide warten auf eine
  # Entscheidung, die nun nicht mehr kommt.
  #
  # Der abgebende Verein und sein Landesverband bekommen bewusst keine eigene
  # Mail -- sie stehen bereits in den Empfaengern von #transfer_completed, und
  # der Vollzug ist dort die Nachricht. Ein zweites Schreiben zum selben Vorgang
  # legte nahe, es sei ein zweiter.
  #
  # `transfer_request` ist die FREIGABE, `transfer` der vollzogene Transfer:
  # Die Mail nennt den neuen Heimatverein, und der steht nur am Transfer.
  def release_annulled_by_transfer(transfer_request, transfer)
    @transfer_request = transfer_request
    @transfer = transfer
    recipients = (transfer_request.requesting_club.notification_emails +
                  [transfer_request.player.email])
                 .map { |mail| mail.to_s.strip }.reject(&:blank?).uniq
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "Spielerfreigabe-Antrag beendet, Spieler transferiert: #{player_name(transfer_request)}",
      placeholders: {
        player_name: player_name(transfer_request),
        club_name: transfer_request.requesting_club.name,
        new_club_name: transfer.requesting_club.name
      }
    )
  end

  def secondary_club_notification(transfer_request, club)
    @transfer_request = transfer_request
    @club = club
    recipients = club.notification_emails
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "Zusatzlizenz/Freigabe entzogen durch Transfer: #{player_name(transfer_request)}",
      placeholders: { player_name: player_name(transfer_request) }
    )
  end

  private

  def player_name(tr)
    "#{tr.player.first_name} #{tr.player.last_name}"
  end

  def release?(tr)
    tr.request_type == 'release'
  end

  def request_noun(tr)
    release?(tr) ? 'Spielerfreigabe-Antrag' : 'Transferantrag'
  end

  # Nur fuer #transfer_scheduled, und dort ist das Datum gesetzt: Ohne Datum in
  # der Zukunft haette `approve_lv` sofort vollzogen statt zu planen. Der
  # Rueckfall haelt trotzdem einen Betreff mit „am " ohne Datum von der Leitung
  # fern, falls die Zeile je aus einem anderen Zustand heraus gerufen wird.
  def effective_date(tr)
    tr.effective_date&.strftime('%d.%m.%Y') || 'dem vereinbarten Termin'
  end
end
