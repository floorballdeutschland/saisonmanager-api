# Ordnet einem Kurs eine Kursleitung zu und sorgt dafuer, dass das Konto die
# Rolle „Kursleitung" (User::COURSE_LEAD_ROLE_ID) traegt.
#
# Drei Wege, je nachdem, was die RSK in der Hand hat:
# - `referee_id`: Schiri aus dem Bestand. Hat er noch kein Konto, wird es ueber
#   RefereeAccountCreator angelegt (mit dessen Begruessungsmail).
# - `user_name`: vorhandenes Konto, etwa einer RSK oder eines Vereinsmanagers.
#   Ueber den Benutzernamen und nicht ueber die E-Mail, weil eine Adresse an
#   mehreren Konten haengen darf.
# - `first_name`, `last_name`, `email`: neue Person. Das Konto heisst
#   `kl-<nachname>` und bekommt eine Einladung mit Link zum Passwort.
#
# Die Rolle wird beim Entfernen der letzten Zuordnung wieder abgenommen
# (#remove), damit ein Konto nicht dauerhaft eine leere Rolle traegt.
class RefereeCourseLeadAssigner
  Result = Struct.new(:lead, :error, :invited, keyword_init: true) do
    def success?
      lead.present?
    end
  end

  def initialize(course)
    @course = course
  end

  def assign(params)
    user, invited, error = resolve_user(params)
    return Result.new(error: error) if error

    lead = nil
    RefereeCourseLead.transaction do
      grant_role!(user)
      lead = @course.leads.find_or_initialize_by(user: user)
      lead.lead = ActiveModel::Type::Boolean.new.cast(params[:lead]) == true if params.key?(:lead)
      lead.save!
    end
    send_invitation(user) if invited
    Result.new(lead: lead, invited: invited)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(error: e.record.errors.full_messages.to_sentence)
  end

  def self.remove(lead)
    user = lead.user
    RefereeCourseLead.transaction do
      lead.destroy!
      next if RefereeCourseLead.exists?(user_id: user.id)

      user.update!(permissions: user.permissions.reject { |p| p['user_group_id'].to_i == User::COURSE_LEAD_ROLE_ID })
    end
  end

  private

  def resolve_user(params)
    if params[:referee_id].present?
      user_for_referee(params[:referee_id])
    elsif params[:user_name].present?
      user = User.where('LOWER(user_name) = ?', params[:user_name].to_s.strip.downcase).first
      user ? [user, false, nil] : [nil, false, 'Kein Benutzerkonto mit diesem Namen gefunden']
    else
      new_user(params)
    end
  end

  def user_for_referee(referee_id)
    referee = Referee.where(merged_into_id: nil).find_by(id: referee_id)
    return [nil, false, 'Schiedsrichter nicht gefunden'] if referee.nil?
    return [referee.user, false, nil] if referee.user

    result = RefereeAccountCreator.new(referee).call
    result.success? ? [result.user, false, nil] : [nil, false, result.error]
  end

  def new_user(params)
    first_name = params[:first_name].to_s.strip
    last_name = params[:last_name].to_s.strip
    email = params[:email].to_s.strip.downcase
    if first_name.blank? || last_name.blank? || email.blank?
      return [nil, false, 'Für eine neue Kursleitung braucht es Vorname, Nachname und E-Mail-Adresse']
    end

    user = User.new(
      user_name: user_name_for(last_name),
      first_name: first_name,
      last_name: last_name,
      email: email,
      password: SecureRandom.hex(12),
      # Gleich mit Rolle: Scheitert danach die Zuordnung, steht das Konto
      # wenigstens nicht rollenlos herum.
      permissions: [{ 'user_group_id' => User::COURSE_LEAD_ROLE_ID }]
    )
    return [nil, false, user.errors.full_messages.to_sentence] unless user.save

    [user, true, nil]
  end

  # `kl-nachname`, bei Kollision `kl-nachname2` usw. Namensbildung wie bei den
  # Gastkonten der Schiedsrichter (RefereeAccountCreator.name_slug).
  def user_name_for(last_name)
    base = "kl-#{RefereeAccountCreator.name_slug(last_name).presence || SecureRandom.hex(3)}"
    candidate = base
    suffix = 1
    while User.where('LOWER(user_name) = ?', candidate).exists?
      suffix += 1
      candidate = "#{base}#{suffix}"
    end
    candidate
  end

  def grant_role!(user)
    return if user.permissions.any? { |p| p['user_group_id'].to_i == User::COURSE_LEAD_ROLE_ID }

    user.update!(permissions: user.permissions + [{ 'user_group_id' => User::COURSE_LEAD_ROLE_ID }])
  end

  # Ein Fehlschlag beim Versand nimmt die Zuordnung nicht zurueck; das Konto
  # kommt ueber „Passwort vergessen" an seinen Zugang.
  def send_invitation(user)
    user.password_reset_token = SecureRandom.uuid
    user.save!(validate: false)
    UserMailer.course_lead_invited(user, @course).deliver_later
  rescue StandardError => e
    Rails.logger.warn("RefereeCourseLeadAssigner: Einladung fuer User #{user.id} fehlgeschlagen: #{e.message}")
  end
end
