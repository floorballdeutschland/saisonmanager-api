class TransferRequestMailer < ApplicationMailer
  # Die beiden Empfaengerkreise der Vorgangsmails. Sie bekommen dieselbe
  # Nachricht, aber in getrennten Sendungen.
  #
  # Bis hierher standen Vereinspostfaecher und die private Adresse der
  # betroffenen Person in einem gemeinsamen `to:`. Damit lag diese Adresse mit
  # der ersten Nachricht beim aufnehmenden Verein -- bevor der Landesverband
  # entschieden hatte, im Weg der Direktzuweisung sogar, ohne dass die Person
  # ueberhaupt gefragt wurde, und ohne dass irgendjemand sie dorthin gegeben
  # haette.
  #
  # Umgekehrt gilt das nicht in derselben Schaerfe, aber es ist auch nicht
  # nichts: `Club#notification_emails` liefert neben `contact_email` die
  # Konto-Adressen der Vereinsmanager. Dass die untereinander sichtbar sind,
  # ist in Kauf genommen -- sie handeln in dieser Rolle fuereinander und haben
  # den Vorgang selbst angestossen. Nicht in Kauf genommen ist die Adresse der
  # betroffenen Person.
  #
  # Die Trennung ist zugleich die Voraussetzung fuer die Datenschutzinformation:
  # Sie gehoert an jede Nachricht an die betroffene Person
  # und an keine an ein Vereinspostfach (siehe #audience_recipients).
  AUDIENCES = %w[clubs player].freeze

  # Verschickt eine Vorgangsmail an beide Empfaengerkreise.
  #
  # Als eine Zeile am Aufrufer und nicht als zwei: Ein spaeterer Aufrufer, der
  # den zweiten Versand vergisst, faellt durch nichts auf -- die betroffene
  # Person bekaeme schlicht keine Nachricht, und im Postfach der Vereine sieht
  # alles richtig aus.
  def self.deliver_to_all_audiences(action, *args, **kwargs)
    AUDIENCES.each do |audience|
      public_send(action, *args, audience:, **kwargs).deliver_later
    end
  end

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

  def clubs_informed_lv_pending(transfer_request, audience: 'clubs')
    @transfer_request = transfer_request
    recipients = audience_recipients(
      audience,
      clubs: transfer_request.requesting_club.notification_emails +
             transfer_request.former_club.notification_emails,
      player: transfer_request.player.email
    )
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

    # Ohne Empfaengerkreis-Parameter, die Mail geht ohnehin nur an die Person --
    # die Datenschutzinformation deshalb hier von Hand. Es ist die erste
    # Nachricht des Vorgangs, die sie erreicht, und damit die Stelle, an der
    # Art. 14 Abs. 3 lit. b DSGVO die Unterrichtung spaetestens verlangt.
    enable_privacy_notice!

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
  def club_deactivated_notification(transfer_request, audience: 'clubs')
    @transfer_request = transfer_request
    recipients = audience_recipients(
      audience,
      clubs: transfer_request.former_club.notification_emails,
      player: transfer_request.player.email
    )
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
  #
  # Getrennte Empfaengerkreise wie #transfer_completed: Die Nachricht kuendigt
  # denselben Vorgang an und ging bis zum Merge mit derselben gemeinsamen
  # `to:`-Liste raus, in der die private Adresse neben den Vereinspostfaechern
  # stand.
  def transfer_scheduled(transfer_request, audience: 'clubs')
    @transfer_request = transfer_request
    former_sa = transfer_request.former_club.state_association
    recipients = audience_recipients(
      audience,
      clubs: transfer_request.requesting_club.notification_emails +
             transfer_request.former_club.notification_emails +
             [former_sa&.effective_sbk_email],
      player: transfer_request.player.email
    )
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

  def transfer_completed(transfer_request, audience: 'clubs')
    @transfer_request = transfer_request
    former_sa = transfer_request.former_club.state_association
    recipients = audience_recipients(
      audience,
      clubs: transfer_request.requesting_club.notification_emails +
             transfer_request.former_club.notification_emails +
             [former_sa&.effective_sbk_email],
      player: transfer_request.player.email
    )
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
  def release_revoked(transfer_request, licenses_invalidated: true, audience: 'clubs')
    @transfer_request = transfer_request
    @licenses_invalidated = licenses_invalidated
    receiving_sa = transfer_request.requesting_club.state_association
    club_mails = transfer_request.requesting_club.notification_emails +
                 transfer_request.former_club.notification_emails +
                 [receiving_sa&.effective_sbk_email]
    player_mail = transfer_request.player.email
    recipients = audience_recipients(audience, clubs: club_mails, player: player_mail)

    # Nicht stumm zurueckkehren wie die uebrigen Mails dieser Datei: Bei keiner
    # von ihnen ist die Folge, dass ein Verein einen nicht mehr
    # spielberechtigten Spieler aufstellt. Ein leerer Verteiler heisst hier,
    # dass der Widerruf ueber keinen einzigen Kanal ankommt -- und der Vorgang
    # faellt aus beiden Listen, sobald er aus der laufenden Saison heraus ist.
    # Gleiches Muster wie PlayerMailer#express_license_requested.
    if recipients.empty?
      report_unreachable_revocation(transfer_request, club_mails, player_mail) if audience.to_s == 'clubs'
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
  def release_annulled_by_transfer(transfer_request, transfer, audience: 'clubs')
    @transfer_request = transfer_request
    @transfer = transfer
    recipients = audience_recipients(
      audience,
      clubs: transfer_request.requesting_club.notification_emails,
      player: transfer_request.player.email
    )
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

  # Waehlt den Verteiler zum Empfaengerkreis und schaltet fuer die betroffene
  # Person zugleich die Datenschutzinformation frei.
  #
  # Beides an einer Stelle und nicht in zwei Aufrufen: Verteiler und
  # Pflichtangabe haengen an derselben Entscheidung, und ein vergessener
  # zweiter Aufruf faellt an keiner Stelle auf -- die Nachricht sieht ohne den
  # Block genauso vollstaendig aus.
  #
  # Ein unbekannter Wert bricht ab, statt in den Vereins-Zweig zu fallen: Ein
  # Tippfehler im Aufruf schickte sonst die als personengerichtet gemeinte
  # Nachricht an die Vereine -- also genau das, was diese Trennung beseitigt.
  def audience_recipients(audience, clubs:, player:)
    raise ArgumentError, "unbekannter Empfaengerkreis: #{audience.inspect}" unless AUDIENCES.include?(audience.to_s)

    if audience.to_s == 'player'
      enable_privacy_notice!
      clean_mails(player).tap { |mails| log_unreachable_player if mails.empty? }
    else
      clean_mails(clubs)
    end
  end

  # Eine Sendung an die Person, die keinen Empfaenger hat, faellt sonst durch
  # nichts auf: `return if recipients.empty?` liefert eine NullMail, und die
  # erzeugt weder eine Zustellung noch eine Zeile im EmailLog. Die Vereine
  # bekommen ihre Nachricht, im Postfach sieht alles vollstaendig aus, und die
  # Einzige, die auf eine Entscheidung wartet, erfaehrt nichts.
  #
  # Nur ins Log und nicht nach Sentry: Eine Person ohne hinterlegte Adresse ist
  # der haeufige Normalfall (die Adresse ist beim Anlegen freiwillig), das waere
  # Rauschen. Nach Sentry geht allein der Fall, in dem die Nachricht NIEMANDEN
  # erreicht -- siehe #report_unreachable_revocation.
  def log_unreachable_player
    Rails.logger.warn(
      "TransferRequestMailer: #{action_name} an die betroffene Person ohne Empfaenger " \
      "(TransferRequest##{@transfer_request&.id})"
    )
  end

  # Das Flag liest das Mailer-Layout (app/views/layouts/mailer.html.erb) und
  # haengt die kurze Datenschutzinformation an. Der zustaendige Verband wird
  # darin benannt: `responsible_state_association` und nicht
  # `state_association`, denn entscheiden darf der Verbund (dieselbe
  # Unterscheidung wie im Text von #pending_lv_notification).
  #
  # Fehlt der Verband, bleibt der Satz "Ueber den Vorgang entscheidet ..." im
  # Partial ersatzlos weg -- die Mail sieht weiterhin vollstaendig aus. Genau
  # deshalb die Logzeile: Eine Pflichtangabe, die still verschwindet, ist keine,
  # und das gilt fuer einen fehlenden Verbandsdatensatz so wie fuer einen
  # ueberschriebenen Vorlagentext. `responsible_state_association` ist ein
  # `find_by` und liefert auch dann nil, wenn der Verein einen Verband hat,
  # dessen Wurzel geloescht wurde.
  def enable_privacy_notice!
    @privacy_notice = true
    @privacy_authority = @transfer_request&.former_club&.responsible_state_association
    return if @privacy_authority.present?

    Rails.logger.warn(
      "TransferRequestMailer: Datenschutzinformation ohne zustaendigen Verband " \
      "(TransferRequest##{@transfer_request&.id}, Club##{@transfer_request&.former_club&.id})"
    )
  end

  def clean_mails(list)
    Array(list).map { |mail| mail.to_s.strip }.reject(&:blank?).uniq
  end

  # Der Alarm haengt am GESAMTEN Verteiler, nicht am eigenen Durchgang: Seit die
  # Nachricht getrennt an Vereine und an die Person geht, ist eine leere Haelfte
  # der Normalfall -- eine Person ohne hinterlegte Adresse, ein aufgeloester
  # Verein ohne Postfach -- und taugt nicht als Alarmgrund. Gemeldet wird nur,
  # was der Alarm von Anfang an meinte: Der Widerruf erreicht niemanden.
  def report_unreachable_revocation(transfer_request, club_mails, player_mail)
    return unless clean_mails(club_mails + Array(player_mail)).empty?
    return unless defined?(Sentry)

    Sentry.capture_message(
      "Widerruf ohne Empfaenger: TransferRequest##{transfer_request.id} -- " \
      'weder Vereine noch Landesverband noch Spieler haben eine Adresse.'
    )
  end

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
