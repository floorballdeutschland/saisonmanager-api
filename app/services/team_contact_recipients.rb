# frozen_string_literal: true

# Adressen, unter denen eine Mannschaft für Vorgänge zu ihrem Spiel erreichbar
# ist. Herausgelöst aus GuestTeamChecklistNotifier, damit Spieltagsbestätigung
# und Protest-Links (GameProtestInviter) dieselbe Kaskade nutzen.
module TeamContactRecipients
  # Eine Kaskade, kein Sammelverteiler: Die Mail geht an die Stufe, die dem
  # Spieltag am nächsten steht, und erst wenn die leer ist an die nächste.
  #
  #   1. die Teammanager DIESER Mannschaft
  #   2. sonst die Vereinsmanager des Vereins (Vereinspost ohne Kontaktadresse)
  #   3. sonst die Kontaktadresse des Vereins
  #
  # Vorher gingen Vereinspost und Teammanager gemeinsam raus. Für einen Verein
  # mit vielen Mannschaften heißt das, dass der Vereinsvorstand jede Bestätigung
  # jeder Mannschaft mitliest, während die Mail tatsächlich an eine einzige
  # Person gerichtet ist – die, die den Spieltag verantwortet.
  #
  # Dass die Stufen sich gegenseitig ausschließen, ist der Punkt der Änderung.
  # Eine Stufe gilt als leer, wenn sie keine zustellbare Adresse liefert, nicht
  # wenn es die Rolle nicht gibt: Ein Teammanager, der Info-Mails abbestellt hat
  # (`receive_info_mails`), lässt die Mail damit an die Vereinsmanager
  # weiterfallen. Das ist gewollt – die Bestätigung ist eine Pflicht des
  # Vereins, sie darf nicht dadurch verschwinden, dass niemand sie lesen will.
  #
  # Geprüft wird auf Zustellbarkeit, nicht auf Befülltheit: `users.email` hat
  # keinerlei Formatvalidierung (anders als `clubs.contact_email`), und ein
  # Teammanager, der den Verein verlassen hat, steht oft mit einem längst
  # gelöschten Postfach weiter an der Mannschaft. Ohne die Prüfung besetzte so
  # ein toter Eintrag die erste Stufe, die Mail bounct, und beide Auffangnetze
  # bleiben ungenutzt, während die Bestätigungsfrist weiterläuft.
  #
  # Für Protest-Links (GameProtestInviter) gilt dieselbe Kaskade samt Abwahl:
  # Ein Teammanager ohne Info-Mails lässt auch den Link an die Vereinsmanager
  # weiterfallen. Auch der Protest ist eine Sache des Vereins, und wer den
  # Link nicht bekommt, wäre der SBK nur als „keine Adresse" aufgefallen.
  #
  # Liefert die gezogene Stufe und ihre Adressen. Die Stufe kommt aus der
  # Ermittlung selbst und wird nicht nachträglich rekonstruiert -- ein zweiter
  # Durchlauf kostete eine weitere Abfrage über die Vereinsmanager.
  def self.for_team(team)
    club = team.club

    if (emails = deliverable(User.team_managers(team.id).map(&:email))).any?
      ['Teammanager', emails]
    elsif (emails = deliverable(vereinsmanager_emails(club))).any?
      ['Vereinsmanager', emails]
    else
      ['Vereinskontaktadresse', deliverable([club&.contact_email])]
    end
  end

  # Die Vereinsmanager der Vereinspost, ohne die, die Info-Mails abbestellt
  # haben (`receive_info_mails`).
  #
  # Die übrige Vereinspost kennt diese Abwahl bewusst nicht: An
  # `Club#notification_emails` hängen Transfers, Spielverlegungen, Freigaben und
  # die Erinnerung an den Spielberichtsbogen -- Vorgänge, die ein Verein
  # mitbekommen muss, ob er mag oder nicht. Für diese eine Mail gilt die Abwahl
  # dagegen schon auf Stufe 1 (`User.team_managers` filtert danach), und sie auf
  # Stufe 2 zu übergehen kehrte den Schalter ins Gegenteil: Ein Vereinsmanager,
  # der sich eine Mannschaft zugeordnet und Info-Mails abbestellt hat, fiel aus
  # Stufe 1 heraus, bekam die Mail über Stufe 2 trotzdem -- und zog dabei den
  # ganzen restlichen Vorstand mit hinein, der vorher nichts davon sah.
  def self.vereinsmanager_emails(club)
    club&.notify_managers.to_a.select(&:receive_info_mails).filter_map { |user| user.email.presence }
  end

  # Zerlegt wird, was der Mail-Versand ohnehin zerlegt, statt es zu verwerfen:
  # Ein Feld mit zwei durch Semikolon oder Komma getrennten Adressen und ein
  # Feld mit Anzeigename (`Max Muster <max@verein.de>`) werden vom Mail-Gem in
  # echte Empfänger aufgelöst, bis in den SMTP-Umschlag. Beides steht im
  # Bestand -- auf der Produktion trägt mindestens ein Verein zwei Adressen mit
  # Semikolon in der Kontaktadresse (siehe Club::EMAIL_FORMAT). Eine reine
  # Formatprüfung auf das ganze Feld hätte genau diese Vereine aus der letzten
  # Stufe der Kaskade geworfen, also aus dem Auffangnetz -- und ohne
  # Empfänger gibt es weder Mail noch Fristverlängerung.
  #
  # Der Kommentar an `Club#reachable_for_requests?` behauptet das Gegenteil
  # („geht als EINE Adresse heraus und erreicht niemanden"). Das ist gemessen
  # falsch; die Stelle gehört nicht zu diesem Weg und bleibt hier unangetastet.
  def self.deliverable(emails)
    emails.flat_map { |mail| mail.to_s.split(/[;,]/) }
          .map { |mail| mail[/<([^>]+)>/, 1] || mail }
          .map(&:strip)
          .select { |mail| mail.match?(Club::EMAIL_FORMAT) }
          .uniq
  end
end
