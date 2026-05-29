class RefereeCourseSubmitPolicy
  # Entscheidet pro Course-Result, ob beim Submit ein LV-Review nötig ist.
  # Regeln:
  #   * 6/6-Match (exact_match) → nie Review.
  #   * Sonst: Review erforderlich, wenn der zugeordnete LV den Kontrollprozess
  #     aktiviert hat. Wenn kein LV ableitbar ist (state_association_id nil),
  #     wird ebenfalls Review erzwungen — Safe-default, damit kein Datensatz
  #     ohne LV-Kontrolle silent durchrutscht.
  def self.review_required?(result, state_association)
    return false if result.match_type == 'exact_match'
    return true  if state_association.nil?

    state_association.effective_referee_license_review_enabled
  end
end
