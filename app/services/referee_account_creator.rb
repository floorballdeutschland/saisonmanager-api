# Legt das Schiedsrichter-Benutzerkonto zu einem Referee an.
#
# Eine Stelle für Einzelanlage (Schiri-Maske) und Massenanlage, damit
# Benutzername, Rolle und Begrüßungsmail nicht auseinanderlaufen: Ein Konto, das
# über den Massenweg entsteht, muss sich in nichts von einem einzeln angelegten
# unterscheiden.
class RefereeAccountCreator
  # Benutzergruppe „Schiedsrichter".
  REFEREE_USER_GROUP_ID = 6

  Result = Struct.new(:user, :error, :email_sent, :duplicate_email, keyword_init: true) do
    def success?
      user.present?
    end
  end

  # Schiedsrichter, die ein Konto bekommen könnten: Adresse hinterlegt, noch kein
  # Konto verknüpft, Lizenznachweis im Fenster.
  #
  # in_career_window verlangt ein vorhandenes Ablaufdatum jünger als der Stichtag.
  # Es schließt damit ZWEI Gruppen aus, nicht eine: die Karriere-Beendeten (rund
  # 4.250 Datensätze aus dem Nachimport) und die Datensätze ganz ohne Ablaufdatum.
  # Letzteres trifft frisch angelegte Schiedsrichter — die bekommen über die
  # Massenanlage also kein Konto, bis eine Gültigkeit eingetragen ist; einzeln
  # anlegen geht weiter. Beides ist gewollt: Wer keinen Lizenznachweis hat, ist
  # kein Fall für einen automatisch erzeugten Zugang.
  #
  # Gäste sind ausgenommen, weil sie keine eigene Zuständigkeit im Verband haben
  # (Aushilfen, meist aus dem Ausland) und kein Selbstverwaltungskonto brauchen.
  # Eine Lizenznummer KANN ein Gast tragen, sie ist für ihn nur nicht Pflicht —
  # der Benutzername hängt an der separaten Bedingung eine Zeile tiefer.
  #
  # canonical ist bereits in in_career_window enthalten und steht hier nur zur
  # Klarheit: Zusammengeführte Dubletten dürfen kein zweites Konto bekommen.
  #
  # where.not(referee_id: nil) im Unterquery ist tragend: Ohne diese Bedingung
  # vergleicht NOT IN gegen NULL und die Kandidatenliste ist immer leer.
  def self.candidates
    Referee.canonical
           .in_career_window
           .where(guest: false)
           .where.not(lizenznummer: nil)
           .where.not(email: [nil, ''])
           .where.not(id: User.where.not(referee_id: nil).select(:referee_id))
  end

  # deliver_later: Für die Massenanlage wird die Begrüßungsmail eingereiht statt im
  # Request verschickt — hundert Zustellungen hintereinander ließen den Request
  # auflaufen, und ein Timeout mittendrin hinterließe Konten, deren Mail nie
  # rausging.
  #
  # Einschränkung, die man kennen muss: Produktion läuft auf dem ActiveJob-Default
  # `:async`, also einem Threadpool im Prozess ohne Persistenz. Ein Deploy oder
  # Neustart mitten in einer Tranche verwirft die noch nicht zugestellten Mails.
  # `email_sent` heißt auf diesem Weg deshalb „eingereiht", nicht „zugestellt".
  # Die Betroffenen kommen über „Passwort vergessen" trotzdem an ihr Konto.
  def initialize(referee, deliver_later: false)
    @referee = referee
    @deliver_later = deliver_later
  end

  def call
    return Result.new(error: 'Diesem Schiedsrichter ist bereits ein Benutzerkonto zugeordnet.') if @referee.user

    # Ohne E-Mail wäre das Konto unbenutzbar: Das Initialpasswort verlässt den
    # Server nur über den Link in der Willkommensmail, und auch „Passwort
    # vergessen" braucht die Adresse.
    if @referee.email.blank?
      return Result.new(error: 'Ohne hinterlegte E-Mail-Adresse kann kein Benutzerkonto angelegt werden. ' \
                               'Bitte zuerst die E-Mail-Adresse im Schiedsrichter-Profil eintragen.')
    end

    duplicate_email = User.exists?(email: @referee.email)
    user = build_user

    unless user.save
      # presence-Fallback: Bricht ein Callback per throw(:abort) ab, ist
      # full_messages leer — der Aufrufer rendert dann 422 ohne jeden Text.
      return Result.new(error: user.errors.full_messages.to_sentence.presence ||
                               'Das Benutzerkonto konnte nicht angelegt werden.')
    end

    Result.new(user: user, email_sent: send_welcome_mail(user), duplicate_email: duplicate_email)
  end

  private

  def build_user
    User.new(
      user_name: user_name,
      first_name: @referee.vorname,
      last_name: @referee.nachname,
      email: @referee.email.presence,
      password: SecureRandom.hex(12),
      permissions: [{ 'user_group_id' => REFEREE_USER_GROUP_ID }],
      referee_id: @referee.id
    )
  end

  def user_name
    @referee.lizenznummer.present? ? "sr-#{@referee.lizenznummer}" : "sr-g#{@referee.id}"
  end

  # Ein Fehlschlag beim Versand darf das Konto nicht wieder wegnehmen: Es ist
  # angelegt und verknüpft, die Mail lässt sich über „Passwort vergessen"
  # nachholen. Der Aufrufer erfährt über email_sent, ob sie rausging.
  def send_welcome_mail(user)
    return false if user.email.blank?

    user.send_referee_account_information(deliver_later: @deliver_later)
  rescue StandardError => e
    Rails.logger.warn("RefereeAccountCreator: Begrüßungs-Mail für User #{user.id} fehlgeschlagen: #{e.message}")
    false
  end
end
