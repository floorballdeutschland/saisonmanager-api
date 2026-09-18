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
  # Gäste bleiben aus der Massenanlage heraus, dürfen aber im Einzelfall ein
  # Konto bekommen (Entscheidung vom 15.09.2026). Sie haben keine eigene
  # Zuständigkeit im Verband (Aushilfen, meist aus dem Ausland), ein pauschal
  # erzeugter Zugang geht deshalb an ihnen vorbei; wer einen braucht, bekommt ihn
  # über den Knopf in der Schiri-Maske. Der Benutzername kommt dann aus dem
  # Nachnamen (siehe user_name_for).
  #
  # where(guest: false) ist heute nicht der einzige Riegel: Ein Gast trägt weder
  # Lizenznummer noch Ablaufdatum und fiele schon an den beiden Bedingungen
  # darunter heraus. Die Zeile steht trotzdem hier, weil sie die Entscheidung
  # trägt und nicht deren Nebenwirkung. Lockert sich der Lizenznachweis je, bleibt
  # der Ausschluss bestehen.
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

  # Der Benutzername eines Schiedsrichterkontos.
  #
  # Gäste tragen seit api#646 keine Lizenznummer mehr, ihr Name kommt deshalb aus
  # dem Nachnamen: `sr-nachname`. Das ist nicht nur Kosmetik — die beiden ersten
  # Gastkonten hießen `sr-8725`/`sr-8726` nach Lizenznummern, die inzwischen
  # wieder im Pool sind. Sobald ein echter Schiedsrichter die 8725 bekommt,
  # scheitert dessen Kontoanlage an der Eindeutigkeit des Namens.
  #
  # Alle anderen behalten `sr-<lizenznummer>`; `sr-g<id>` bleibt der Notnagel für
  # einen Datensatz, aus dem sich weder Nummer noch verwertbarer Nachname
  # gewinnen lässt.
  #
  # ignore_user_id: Beim Umbenennen eines bestehenden Kontos zählt der eigene
  # Name nicht als Kollision, sonst bekäme ein schon passend benanntes Konto bei
  # jedem Lauf eine weitere Ziffer.
  def self.user_name_for(referee, ignore_user_id: nil)
    unless referee.guest?
      return referee.lizenznummer.present? ? "sr-#{referee.lizenznummer}" : "sr-g#{referee.id}"
    end

    slug = name_slug(referee.nachname)
    return "sr-g#{referee.id}" if slug.blank?

    unique_user_name("sr-#{slug}", ignore_user_id: ignore_user_id)
  end

  # Nachname → Namensbestandteil im erlaubten Zeichensatz (USER_NAME_FORMAT lässt
  # keine Umlaute zu). Deutsche Umlaute werden ausgeschrieben (ö→oe), bevor
  # I18n.transliterate sie zu „o" verkürzen könnte; alles Übrige geht den
  # allgemeinen Weg über die Transliteration. Was danach noch übrig bleibt (das
  # „?" für nicht abbildbare Zeichen ebenso wie Leerzeichen und Apostrophe),
  # wird zum Bindestrich zusammengezogen: „van der Berg" → „van-der-berg",
  # „O'Brien" → „o-brien".
  def self.name_slug(value)
    umlauts = value.to_s.unicode_normalize(:nfc).downcase
                   .gsub('ä', 'ae').gsub('ö', 'oe').gsub('ü', 'ue').gsub('ß', 'ss')
    I18n.transliterate(umlauts, locale: :de)
        .downcase
        .gsub(/[^a-z0-9]+/, '-')
        .delete_prefix('-')
        .delete_suffix('-')
  end

  # Zwei Gäste desselben Nachnamens bekommen sr-nielsen und sr-nielsen2. Die
  # Prüfung läuft kleinschreibungsneutral, weil der Login das auch tut
  # (User.login vergleicht gegen LOWER(user_name)) — sonst entstünde ein Name,
  # der sich zwar speichern lässt, aber auf denselben Login zeigt.
  def self.unique_user_name(base, ignore_user_id: nil)
    candidate = base
    suffix = 1

    while user_name_taken?(candidate, ignore_user_id)
      suffix += 1
      candidate = "#{base}#{suffix}"
    end

    candidate
  end

  def self.user_name_taken?(candidate, ignore_user_id)
    scope = User.where('LOWER(user_name) = ?', candidate.downcase)
    scope = scope.where.not(id: ignore_user_id) if ignore_user_id
    scope.exists?
  end
  private_class_method :name_slug, :unique_user_name, :user_name_taken?

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
      user_name: self.class.user_name_for(@referee),
      first_name: @referee.vorname,
      last_name: @referee.nachname,
      email: @referee.email.presence,
      password: SecureRandom.hex(12),
      permissions: [{ 'user_group_id' => REFEREE_USER_GROUP_ID }],
      referee_id: @referee.id
    )
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
