# Ansetzungsmodus einer Liga (#403). Die einzige Stelle, die den Sonderfall
# Bundesspielbetrieb mit den gestaffelten Verbandsschaltern zusammenbringt;
# Autorisierung, Anlege-Voreinstellung und LeaguesController#additional_references
# fragen hier bzw. bei StateAssociation#referee_assignment_mode nach.
module LeagueRefereeAssignment
  extend ActiveSupport::Concern

  # :none   – nur die SBK setzt an (Weg 1, Freitext am Spiel)
  # :club   – RSK pflegt Verein oder Freitext (Weg 3, reduzierte Ansicht)
  # :person – Ansetzer-Rolle setzt personenscharf an (Weg 2)
  #
  # „National" kommt ausdrücklich aus GameOperation#national und NICHT aus einem
  # fehlenden Landesverband: die FD-GameOperation hat sehr wohl einen
  # StateAssociation-Datensatz (für das Verbandslogo), siehe die Begründung in
  # User#permission_hash. Über `state_association.nil?` liefe der
  # Bundesspielbetrieb still in die LV-Schalter – und fiele aus der Ansetzung,
  # sobald dort jemand den Hauptschalter abwählt.
  def referee_assignment_mode
    go = game_operation
    return :person if go.nil? || go.national?

    sa = go.state_association
    return :person if sa.nil?

    sa.referee_assignment_mode
  end

  # Neue Spiele dieser Liga gleich für die Personenebene markieren? Der
  # Bundesspielbetrieb hat dafür keinen Schalter und bleibt ohne Voreinstellung:
  # dort setzt die SBK die Markierung wie bisher je Spiel.
  def person_level_assignment_default?
    return false unless referee_assignment_mode == :person

    game_operation&.state_association&.person_level_assignment_default? || false
  end
end
