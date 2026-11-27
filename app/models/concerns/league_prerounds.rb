# Vorrunden-Ligen einer Liga: aus ihnen übernimmt die Tabelle Punkte
# (`preround_point_modus`) und `copy_preround_licenses` die Lizenzen.
#
# Eine Liga kann mehrere Vorrunden haben. Bayern spielt die Vorrunde in
# Staffel A und B und bildet daraus eine Zwischenrunde bzw. eine Meister- und
# eine Platzierungsrunde, in die jede Mannschaft die Punkte ihrer Staffel
# mitnimmt.
#
# Was übernommen wird, legt `preround_transfer_scope` fest (PREROUND_SCOPES):
# nur Punkte, Punkte und Tore, oder die komplette Bilanz. Ob überhaupt etwas
# übernommen wird und ob die Punkte halbiert werden, steht weiter in
# `preround_point_modus` (nil / full / half). „Halb“ gilt nur für Punkte.
#
# `league_ids_preround` ist die führende Spalte. `league_id_preround` hält
# weiter die erste Vorrunde, weil der Altersklassen-Fallback
# (LeagueCompetition#preround_league), die Playoff-Erkennung und ältere
# Clients sie lesen.
module LeaguePrerounds
  extend ActiveSupport::Concern

  # Tiefe, bis zu der Vorrunden von Vorrunden verfolgt werden (Vorrunde ->
  # Zwischenrunde -> Meisterrunde braucht zwei). Schutz gegen Ringe, die an
  # der Validierung vorbei per update_column entstehen.
  MAX_PREROUND_DEPTH = 5

  # Welche Tabellenwerte eine Stufe aus der Vorrunde übernimmt. Leer gilt als
  # `points`, das Verhalten vor Einführung der Einstellung.
  PREROUND_SCOPES = {
    'points' => %i[points],
    'goals' => %i[points goals_scored goals_received],
    'full' => %i[points goals_scored goals_received games won draw lost won_ot lost_ot]
  }.freeze

  included do
    before_validation :sync_preround_columns
    validate :preround_leagues_without_cycle
    validates :preround_transfer_scope, inclusion: { in: PREROUND_SCOPES.keys }, allow_blank: true
  end

  class_methods do
    # Ligen, die `league_id` als Vorrunde führen, samt deren Folgeligen.
    # Ihre Tabellen hängen an den Ergebnissen von `league_id`.
    def dependent_on_preround(league_id)
      found = []
      frontier = [league_id.to_i]
      MAX_PREROUND_DEPTH.times do
        ids = League.unscoped.where('league_ids_preround && ARRAY[?]::bigint[]', frontier).pluck(:id) - found
        ids -= [league_id.to_i]
        break if ids.empty?

        found.concat(ids)
        frontier = ids
      end
      found
    end
  end

  def preround_league_ids
    Array(league_ids_preround).map(&:to_i).reject { |i| i.zero? || i == id }.uniq
  end

  def preround_leagues
    ids = preround_league_ids
    return [] if ids.empty?

    by_id = League.unscoped.where(id: ids).index_by(&:id)
    ids.filter_map { |i| by_id[i] }
  end

  # Ordnet jeder Mannschaft dieser Liga ihre Mannschaft aus den Vorrunden zu:
  # { team_id dieser Liga => Team der Vorrunde }.
  #
  # Eine Mannschaft hat in jeder Liga eine eigene ID, deshalb läuft die
  # Zuordnung über den Verein. Hat ein Verein mehrere Mannschaften (etwa „1“
  # in Staffel A und „2“ in Staffel B), entscheidet der Mannschaftsname, dann
  # das Kürzel. Bleibt es mehrdeutig, bekommt die Mannschaft nichts: Keine
  # Punkte sind sichtbar falsch, fremde Punkte nicht.
  #
  # Spielt dieselbe Mannschaft (gleiche ID, etwa über `cup_leagues`) in Vorrunde
  # und Folgeliga, ist sie ohne Umweg sie selbst.
  def preround_team_matches(preround_teams: all_preround_teams, current_teams: teams.to_a)
    candidates_by_club = preround_teams.group_by(&:club_id)
    current_count_by_club = current_teams.group_by(&:club_id).transform_values(&:size)

    current_teams.each_with_object({}) do |team, matches|
      candidates = candidates_by_club[team.club_id] || []
      next if candidates.empty?

      match = if (same = candidates.find { |c| c.id == team.id })
                same
              elsif candidates.size == 1 && current_count_by_club[team.club_id] == 1
                candidates.first
              else
                unique_team_match(candidates, team, :name) || unique_team_match(candidates, team, :short_name)
              end

      if match
        matches[team.id] = match
      else
        Rails.logger.warn(
          "Vorrunde: Mannschaft #{team.id} (Liga #{id}) nicht eindeutig zuzuordnen, " \
          "Kandidaten #{candidates.map(&:id).join(', ')}"
        )
      end
    end
  end

  # Alle Mannschaften der Vorrunden, wie League#teams auch die, die nur über
  # `cup_leagues` dazugehören (Pokal- und Playoff-Ligen).
  def all_preround_teams
    ids = preround_league_ids
    return [] if ids.empty?

    Team.where(league_id: ids).or(Team.where('cup_leagues && ARRAY[?]::integer[]', ids)).to_a
  end

  private

  def unique_team_match(candidates, team, attribute)
    key = normalized_team_key(team.public_send(attribute))
    return nil if key.blank?

    hits = candidates.select { |c| normalized_team_key(c.public_send(attribute)) == key }
    hits.size == 1 ? hits.first : nil
  end

  def normalized_team_key(value)
    value.to_s.squish.downcase
  end

  # Addiert die Vorrundenwerte der gewählten Stufe. Je Mannschaft wird über
  # alle Vorrunden summiert und erst dann halbiert und abgerundet, damit „halb“
  # nicht je Staffel einzeln abrundet.
  #
  # `preround_points` bleibt für bestehende Clients; `preround` nennt alle
  # übernommenen Werte, damit die Tabelle sie kennzeichnen kann.
  def apply_preround_points!(results, visited)
    return if preround_point_modus.blank?

    leagues = preround_leagues.reject { |l| visited.include?(l.id) }
    return if leagues.empty?

    fields = PREROUND_SCOPES.fetch(preround_transfer_scope.presence || 'points', PREROUND_SCOPES['points'])
    totals = Hash.new { |h, k| h[k] = Hash.new(0) }
    leagues.each do |preround|
      preround.table(visited: visited + [preround.id]).each do |entry|
        fields.each { |f| totals[entry[:team_id]][f] += entry[f].to_f }
      end
    end

    matches = preround_team_matches(preround_teams: Team.where(id: totals.keys).to_a,
                                    current_teams: Team.where(id: results.keys).to_a)

    matches.each do |team_id, preround_team|
      entry = results[team_id]
      next unless entry

      transfer = preround_transfer_values(totals[preround_team.id], fields)
      next if transfer.values.all?(&:zero?)

      transfer.each { |f, v| entry[f] += v }
      entry[:goals_diff] = entry[:goals_scored] - entry[:goals_received]
      entry[:preround_points] = transfer[:points] unless transfer[:points].zero?
      entry[:preround] = transfer
    end
  end

  def preround_transfer_values(total, fields)
    multiplier = preround_point_modus == 'half' ? 0.5 : 1.0
    fields.index_with do |f|
      f == :points ? (total[f] * multiplier).floor : total[f].to_i
    end
  end

  def sync_preround_columns
    if will_save_change_to_league_ids_preround?
      self.league_ids_preround = Array(league_ids_preround).filter_map { |v| v.presence&.to_i }.uniq
      self.league_id_preround = league_ids_preround.first
    elsif will_save_change_to_league_id_preround?
      self.league_ids_preround = [league_id_preround].compact
    end
  end

  def preround_leagues_without_cycle
    return unless will_save_change_to_league_ids_preround?

    ids = Array(league_ids_preround)
    return if ids.empty?

    if persisted? && ids.include?(id)
      errors.add(:league_ids_preround, 'darf nicht die Liga selbst enthalten')
      return
    end
    return unless persisted?

    frontier = ids
    MAX_PREROUND_DEPTH.times do
      next_ids = League.unscoped.where(id: frontier).pluck(:league_ids_preround).flatten.uniq
      if next_ids.include?(id)
        errors.add(:league_ids_preround, 'bildet einen Ring: eine Vorrunde verweist auf diese Liga zurück')
        return
      end
      break if next_ids.empty?

      frontier = next_ids
    end
  end
end
