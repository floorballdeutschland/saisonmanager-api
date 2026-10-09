# Wer welche Schiedsrichterkurse verwalten darf.
#
# - Admin und FD-RSK (RSK mit globalem Scope): alle Kurse, auch bundesweite.
# - LV-RSK: Kurse, an denen einer ihrer Landesverbaende beteiligt ist
#   (verantwortlich oder Partner). Die LV ergeben sich wie bei der
#   Kursfreigabe ueber den Verbandsbaum (Club.responsible_state_association_ids),
#   nicht ueber die Spalte des Spielbetriebs.
#
# Zusaetzlich gilt der Schalter „Kurse im System" (Setting.referee_courses_enabled?):
# Kurse eines nicht freigeschalteten LV sind auch fuer berechtigte Konten nicht
# erreichbar.
class RefereeCoursePolicy
  def initialize(user)
    @user = user
    @ph = user&.permission_hash || {}
  end

  def global?
    @ph[:admin].present? || (@ph[:rsk].present? && @ph[:rsk].include?(0))
  end

  # :all fuer globalen Zugriff, sonst die Liste der LV-ids (ggf. leer).
  def state_association_ids
    return :all if global?
    return [] if @ph[:rsk].blank?

    @state_association_ids ||= Club.responsible_state_association_ids(@ph[:rsk])
  end

  # Ob das Konto ueberhaupt Kurse verwalten kann und der Prozess fuer
  # mindestens einen seiner LV an ist. Steuert den Menuepunkt.
  def any_access?
    ids = state_association_ids
    return Setting.referee_courses_enabled? if ids == :all

    ids.any? { |sa_id| Setting.referee_courses_enabled?(sa_id) }
  end

  def scope
    ids = state_association_ids
    return RefereeCourse.all if ids == :all
    return RefereeCourse.none if ids.empty?

    RefereeCourse.where(state_association_id: ids)
                 .or(RefereeCourse.where('partner_state_association_ids && ARRAY[?]::integer[]', ids))
  end

  def manage?(course)
    return false unless course.process_enabled?

    ids = state_association_ids
    return true if ids == :all

    course.managing_state_association_ids.intersect?(ids)
  end

  # Darf einen Kurs fuer diesen LV anlegen bzw. ihm zuordnen. nil heisst
  # bundesweit und bleibt Admin/FD-RSK vorbehalten.
  def assign_state_association?(state_association_id)
    return false unless Setting.referee_courses_enabled?(state_association_id)

    ids = state_association_ids
    return true if ids == :all
    return false if state_association_id.nil?

    ids.include?(state_association_id.to_i)
  end
end
