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
  # in_career_window schließt die Karriere-Beendeten aus (rund 4.250 Datensätze
  # aus dem Nachimport). Ein Konto für jemanden, der seit vier Lizenzjahren nicht
  # mehr pfeift, hilft niemandem und würde die Massenanlage zur Hälfte mit
  # Historie füllen. Gäste haben keine Lizenznummer und damit keinen stabilen
  # Benutzernamen.
  def self.candidates
    Referee.canonical
           .in_career_window
           .where(guest: false)
           .where.not(lizenznummer: nil)
           .where.not(email: [nil, ''])
           .where.not(id: User.where.not(referee_id: nil).select(:referee_id))
  end

  # deliver_later: Für die Massenanlage wird die Begrüßungsmail in die Queue
  # gelegt statt im Request verschickt — hundert Zustellungen hintereinander
  # ließen den Request auflaufen und ein Timeout mittendrin hinterließe Konten,
  # deren Mail nie rausging.
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

    return Result.new(error: user.errors.full_messages.to_sentence) unless user.save

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
