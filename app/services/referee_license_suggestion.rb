# Lizenzvorschlag für ein Kursergebnis aus den Kursen im System (api#861). Nur
# ein Vorschlag: Die Lizenz legt weiter FD in der Lizenzvergabe fest.
#
# Kandidaten sind die Regeln zum Kurstyp, in ihrer Reihenfolge und beschränkt
# auf die Stufen, die der Kurs vergibt (license_level_ids; ein Kurs ohne
# Stufen schränkt nicht ein). Gewählt wird die erste, deren Mindestzahl an
# Spielen erreicht ist. So ergibt ein J-Kurs mit Zielstufe J2 die J2, obwohl
# die J1-Regel davor steht.
#
# Maßgebliche Saison ist die, die im Kalenderjahr vor dem Kursende begann:
# Kursende Juni 2026 und September 2026 zählen 2025/26, Januar 2027 zählt die
# laufende 2026/27. Das hängt nur am Datum, ein früher oder später manueller
# Saisonwechsel ändert den Vorschlag nicht (Entscheidung 26.10.2026).
class RefereeLicenseSuggestion
  def self.for(result)
    new(result).call
  end

  def self.reference_season_id(kursstichtag)
    kursstichtag && Setting.season_id_starting_in(kursstichtag.year - 1)
  end

  def initialize(result)
    @result = result
    @course = result.referee_course
  end

  # { lizenzstufe:, rule_id:, season_id:, season_name:, games:, min_games: } oder nil
  def call
    return nil if @course.nil?

    season_id = self.class.reference_season_id(@result.kursstichtag)
    candidate_rules.each do |rule|
      games = rule.min_games && count(rule, season_id)
      next if rule.min_games && games < rule.min_games

      return {
        lizenzstufe: rule.referee_license_level.name,
        rule_id: rule.id,
        season_id: season_id,
        season_name: season_id && (Setting.season_name(season_id) || season_id.to_s),
        games: games,
        min_games: rule.min_games
      }
    end
    nil
  end

  private

  def candidate_rules
    rules = RefereeLicenseSuggestionRule.where(course_type: @course.course_type)
                                        .includes(:referee_license_level).order(:position, :id)
    allowed = Array(@course.license_level_ids)
    rules = rules.where(referee_license_level_id: allowed) if allowed.any?
    rules.select { |r| r.referee_license_level.active }
  end

  # Ohne zugeordneten Schiedsrichter (neue Person) oder ohne bestimmbare Saison
  # gibt es keine Einsätze, eine Regel mit Mindestzahl greift dann nicht.
  def count(rule, season_id)
    return 0 if @result.referee.nil? || season_id.nil?

    RefereeSeasonGameStats.count(@result.referee, season_id: season_id, field_size: rule.field_size,
                                                  age_groups: rule.age_groups)
  end
end
