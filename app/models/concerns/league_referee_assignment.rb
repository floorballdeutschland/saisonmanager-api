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
  # Der Modus haengt am Spielbetrieb, nicht an der einzelnen Liga; entschieden
  # wird er in GameOperation#referee_assignment_mode (inklusive des Sonderfalls
  # Bundesspielbetrieb). Eine Liga ohne Spielbetrieb kann nicht angesetzt werden
  # und faellt wie dort auf :person zurueck.
  def referee_assignment_mode
    game_operation&.referee_assignment_mode || :person
  end

  # Neue Spiele dieser Liga gleich für die Personenebene markieren? Der
  # Bundesspielbetrieb hat dafür keinen Schalter und bleibt ohne Voreinstellung:
  # dort setzt die SBK die Markierung wie bisher je Spiel.
  def person_level_assignment_default?
    return false unless referee_assignment_mode == :person

    game_operation&.state_association&.effective_person_level_assignment_default || false
  end
end
