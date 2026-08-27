# Die Spielerdaten-Rangliste: Einsaetze, Tore, Vorlagen und Strafminuten je Person und
# Verein, saisonuebergreifend (Issue #465, Frontend #300).
#
# Gerechnet wird nicht im Request, sondern einmal pro Nacht in ein Aggregat
# (player_game_stats). Warum, steht in der Migration; wie, in PlayerStats::Refresher.
# Gelesen wird es vom Admin::PlayerStatisticsController.
module PlayerStats
  # Strafminuten je Strafkategorie aus Game#evaluate_scorer.
  #
  # Dieselben Gewichte wie in PlayersController#stats_by_season -- die Ansicht im
  # Spielerprofil und die Rangliste muessen fuer dieselbe Person dieselbe Zahl zeigen,
  # sonst ist eine von beiden falsch und niemand weiss, welche.
  # rubocop:disable Naming/VariableNumber -- die Schluessel stammen unveraendert aus
  # Game#empty_score; ein anderer Name waere hier ein anderer Schluessel.
  PENALTY_WEIGHTS = {
    penalty_2: 2,
    penalty_2and2: 4,
    penalty_5: 5,
    penalty_10: 10,
    penalty_ms_tech: 25,
    penalty_ms_full: 25,
    penalty_ms1: 25,
    penalty_ms2: 25,
    penalty_ms3: 25
  }.freeze
  # rubocop:enable Naming/VariableNumber

  def self.penalty_minutes(score)
    PENALTY_WEIGHTS.sum { |key, weight| score[key].to_i * weight }
  end
end
