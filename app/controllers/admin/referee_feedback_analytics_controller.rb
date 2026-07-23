require 'csv'

module Admin
  # Übergreifende Auswertung des Vereins-Feedbacks zu Schiedsrichtern (#181).
  # Anders als die Einzelsicht am Schiri-Profil (RefereesController#feedbacks)
  # aggregiert dieser Endpoint über ALLE Schiris und optional eine per Tag
  # definierte Top-Gruppe. Gleiche Sichtbarkeit wie dort: Admin / FD-RSK /
  # FD-Ansetzer (global).
  #
  # Bewusste Modellierungsentscheidungen (siehe Issue #181):
  # * Nur `status = 'visible'` fließt in die Kennzahlen (moderierte
  #   Rückmeldungen bleiben außen vor, wie am Profil).
  # * Eine Rückmeldung bewertet das GESPANN, hängt also an referee1 UND
  #   referee2. Für die Schiri-Tabelle zählt jede Rückmeldung daher bei beiden
  #   beteiligten Schiris (ein Datenpunkt je Schiri) inkl. der Gespann-Partner.
  #   Für Gesamt-/Gruppen-Mittelwert und Zeitreihe zählt jede Rückmeldung genau
  #   einmal, damit „gesamt" und „Gruppe" direkt vergleichbar bleiben.
  # * Fallzahl: Schiris unter `min_count` (Default 3) werden mit `ranked: false`
  #   markiert, bleiben aber sichtbar; die Anzahl steht immer dabei.
  # * Bewerter-Bias: Der Ausgang des abgebenden Teams ist ableitbar; per
  #   `result`-Filter (won/lost) lassen sich die Rückmeldungen nach Ergebnis des
  #   bewertenden Teams aufschlüsseln.
  class RefereeFeedbackAnalyticsController < ApplicationController
    # Notenbänder für die Verteilung der Schiri-Mittelwerte. Halboffene Bereiche,
    # damit auch Nachkommawerte (z. B. 8.5) lückenlos genau einem Band zufallen.
    RATING_BANDS = [['1-2', 1.0...3.0], ['3-4', 3.0...5.0], ['5-6', 5.0...7.0],
                    ['7-8', 7.0...9.0], ['9-10', 9.0..10.0]].freeze
    DEFAULT_MIN_COUNT = 3
    XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'.freeze

    before_action :authorize_feedback_view!

    # GET /api/v2/admin/referee_feedback_analytics
    def index
      render json: build_report
    end

    # GET /api/v2/admin/referee_feedback_analytics/export.(csv|xlsx)
    def export
      referees = build_report[:referees]
      respond_to do |format|
        format.csv { send_data referees_csv(referees), filename: export_filename('csv'), type: 'text/csv' }
        format.xlsx { send_data referees_xlsx(referees), filename: export_filename('xlsx'), type: XLSX_MIME }
      end
    end

    private

    # Schiri-Feedback ist nur für Admin sowie die FD-Rollen (global gescopt, d. h.
    # rsk/ansetzer enthalten 0) sichtbar, identisch zur Moderation und zur
    # Einzelsicht am Profil.
    def authorize_feedback_view!
      ph = current_user.permission_hash
      return if ph[:admin].present?
      return if ph[:rsk].present? && ph[:rsk].include?(0)
      return if ph[:ansetzer].present? && ph[:ansetzer].include?(0)

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def build_report
      feedbacks = filtered_feedbacks(current_period_feedbacks)
      group_ids = group_referee_ids
      per_referee = referee_stats(feedbacks, group_ids)

      {
        filters: applied_filters,
        overall: aggregate(feedbacks).merge(distribution: distribution(per_referee.values)),
        group: group_report(feedbacks, group_ids, per_referee),
        referees: per_referee.values.sort_by { |r| [-r[:count], r[:referee_name].to_s] },
        time_series: {
          overall: time_series(feedbacks),
          group: group_ids.any? ? time_series(feedbacks.select { |f| in_group?(f, group_ids) }) : []
        }
      }
    end

    # --- Datenbeschaffung -----------------------------------------------------

    def current_period_feedbacks
      load_feedbacks(season_id: season_id, league_id: league_id)
    end

    # Lädt sichtbare Rückmeldungen inkl. der für Aggregation/JSON nötigen
    # Assoziationen. Saison/Liga werden auf DB-Ebene vorgefiltert (Join über
    # games → game_days → leagues); Datum und Ergebnis erst in Ruby, weil
    # game_days.date eine Textspalte ist und das Ergebnis aus JSONB-Events
    # berechnet wird.
    def load_feedbacks(season_id: nil, league_id: nil)
      rel = RefereeFeedback.visible
                           .joins(game: { game_day: :league })
                           .includes(:team, :referee1, :referee2, game: { game_day: :league })
      rel = rel.where(leagues: { season_id: season_id }) if season_id.present?
      rel = rel.where(leagues: { id: league_id }) if league_id.present?
      rel.to_a
    end

    def filtered_feedbacks(feedbacks)
      feedbacks = feedbacks.select { |f| in_date_range?(f) } if from_date || to_date
      feedbacks = feedbacks.select { |f| team_outcome(f) == result_filter } if result_filter
      feedbacks
    end

    def in_date_range?(feedback)
      date = game_date(feedback)
      return false if date.nil?
      return false if from_date && date < from_date
      return false if to_date && date > to_date

      true
    end

    # --- Aggregation ----------------------------------------------------------

    def aggregate(feedbacks)
      {
        count: feedbacks.size,
        avg_line_rating: average(feedbacks, :line_rating),
        avg_communication_rating: average(feedbacks, :communication_rating)
      }
    end

    def average(feedbacks, attribute)
      return nil if feedbacks.empty?

      (feedbacks.sum(&attribute).to_f / feedbacks.size).round(1)
    end

    # Verteilung „Anzahl Schiris je Notenband": bewusst über die Schiri-
    # Mittelwerte (nicht über einzelne Rückmeldungen).
    def distribution(stats)
      {
        line: band_counts(stats, :avg_line_rating),
        communication: band_counts(stats, :avg_communication_rating)
      }
    end

    def band_counts(stats, key)
      RATING_BANDS.each_with_object({}) do |(label, range), acc|
        acc[label] = stats.count { |r| r[key] && range.cover?(r[key]) }
      end
    end

    def group_report(feedbacks, group_ids, per_referee)
      return nil if group_ids.empty?

      group_feedbacks = feedbacks.select { |f| in_group?(f, group_ids) }
      group_referees = per_referee.values.select { |r| r[:in_group] }
      aggregate(group_feedbacks).merge(
        tag_id: tag_id,
        tag_name: RefereeTag.where(id: tag_id).pick(:name),
        distribution: distribution(group_referees)
      )
    end

    # Je Schiri ein Datenpunkt pro beteiligter Rückmeldung (referee1 UND
    # referee2). Der Trend vergleicht mit der Vorperiode (sofern ableitbar).
    def referee_stats(feedbacks, group_ids)
      stats = {}
      feedbacks.each do |feedback|
        each_linked_referee(feedback) do |referee, partner|
          entry = stats[referee.id] ||= new_referee_entry(referee, group_ids)
          entry[:_line] << feedback.line_rating
          entry[:_communication] << feedback.communication_rating
          entry[:partners] << partner if partner.present?
        end
      end

      prev = previous_period_averages
      stats.each_value { |entry| finalize_referee_entry(entry, prev) }
      stats
    end

    def new_referee_entry(referee, group_ids)
      {
        referee_id: referee.id,
        referee_name: referee_display(referee),
        lizenznummer: referee.lizenznummer,
        in_group: group_ids.include?(referee.id),
        _line: [],
        _communication: [],
        partners: []
      }
    end

    def finalize_referee_entry(entry, prev)
      count = entry[:_line].size
      avg_line = round1(entry.delete(:_line))
      avg_communication = round1(entry.delete(:_communication))
      prev_entry = prev && prev[entry[:referee_id]]

      entry.merge!(
        count: count,
        ranked: count >= min_count,
        avg_line_rating: avg_line,
        avg_communication_rating: avg_communication,
        avg_line_rating_prev: prev_entry&.dig(:avg_line_rating),
        avg_communication_rating_prev: prev_entry&.dig(:avg_communication_rating),
        trend_line: trend(avg_line, prev_entry&.dig(:avg_line_rating)),
        trend_communication: trend(avg_communication, prev_entry&.dig(:avg_communication_rating)),
        partners: entry[:partners].uniq.sort
      )
    end

    # Zeitreihe je Monat (aus game_days.date, Textspalte → geparst).
    def time_series(feedbacks)
      feedbacks.group_by { |f| game_date(f)&.strftime('%Y-%m') }
               .reject { |period, _| period.nil? }
               .sort_by { |period, _| period }
               .map { |period, group| aggregate(group).merge(period: period) }
    end

    # --- Vorperiode/Trend -----------------------------------------------------

    # Mittelwerte je Schiri in der Vorperiode. Zwei ableitbare Fälle:
    #   * Datumsfenster gesetzt → unmittelbar vorangehendes, gleich langes Fenster
    #   * sonst Saison gesetzt → Vorsaison (season_id - 1), Liga-Filter entfällt
    # Ohne beides gibt es keinen Vergleichsmaßstab (Trend = nil).
    def previous_period_averages
      feedbacks = previous_period_feedbacks
      return nil if feedbacks.nil?

      per_referee = Hash.new { |h, k| h[k] = { line: [], communication: [] } }
      feedbacks.each do |feedback|
        each_linked_referee(feedback) do |referee, _partner|
          per_referee[referee.id][:line] << feedback.line_rating
          per_referee[referee.id][:communication] << feedback.communication_rating
        end
      end

      per_referee.transform_values do |v|
        { avg_line_rating: round1(v[:line]), avg_communication_rating: round1(v[:communication]) }
      end
    end

    def previous_period_feedbacks
      if from_date && to_date
        span = to_date - from_date
        prev_to = from_date - 1
        prev_from = prev_to - span
        window = load_feedbacks(season_id: season_id, league_id: league_id)
        result_scope(window.select { |f| (d = game_date(f)) && d >= prev_from && d <= prev_to })
      elsif season_id.present?
        prev_season = (season_id.to_i - 1).to_s
        result_scope(load_feedbacks(season_id: prev_season))
      end
    end

    def result_scope(feedbacks)
      return feedbacks unless result_filter

      feedbacks.select { |f| team_outcome(f) == result_filter }
    end

    # --- Ergebnis-/Datums-Helfer ---------------------------------------------

    # Ausgang des bewertenden Teams (:won/:lost/:draw/nil). Das Ergebnis wird aus
    # JSONB-Events berechnet und je Spiel genau einmal gecacht (mehrere
    # Rückmeldungen teilen sich ein Spiel: Heim + Gast).
    def team_outcome(feedback)
      game = feedback.game
      result = game_result(game)
      return nil if result.nil?

      return :draw if result[:home_goals] == result[:guest_goals]

      winner = result[:home_goals] > result[:guest_goals] ? game.home_team_id : game.guest_team_id
      feedback.team_id == winner ? :won : :lost
    end

    def game_result(game)
      game_results_cache.fetch(game.id) { |id| game_results_cache[id] = game.result }
    end

    def game_results_cache
      @game_results_cache ||= {}
    end

    def game_date(feedback)
      game_dates_cache.fetch(feedback.game_id) do |id|
        game_dates_cache[id] = parse_date(feedback.game&.game_day&.date)
      end
    end

    def game_dates_cache
      @game_dates_cache ||= {}
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # --- Gemeinsame Helfer ----------------------------------------------------

    def each_linked_referee(feedback)
      partner_of = { feedback.referee1_id => feedback.referee2,
                     feedback.referee2_id => feedback.referee1 }
      [feedback.referee1, feedback.referee2].compact.each do |referee|
        yield referee, referee_display(partner_of[referee.id])
      end
    end

    def in_group?(feedback, group_ids)
      group_ids.include?(feedback.referee1_id) || group_ids.include?(feedback.referee2_id)
    end

    def group_referee_ids
      return [] if tag_id.blank?

      RefereeTagging.where(referee_tag_id: tag_id).pluck(:referee_id).to_set
    end

    def referee_display(referee)
      return nil if referee.nil?

      "#{referee.vorname} #{referee.nachname}".strip
    end

    def round1(values)
      return nil if values.empty?

      (values.sum.to_f / values.size).round(1)
    end

    def trend(current, previous)
      return nil if current.nil? || previous.nil?

      (current - previous).round(1)
    end

    # --- Parameter ------------------------------------------------------------

    def season_id
      params[:season_id].presence
    end

    def league_id
      params[:league_id].presence
    end

    def tag_id
      params[:tag_id].presence
    end

    def from_date
      return @from_date if defined?(@from_date)

      @from_date = parse_date(params[:from])
    end

    def to_date
      return @to_date if defined?(@to_date)

      @to_date = parse_date(params[:to])
    end

    def result_filter
      case params[:result].to_s
      when 'won' then :won
      when 'lost' then :lost
      end
    end

    def min_count
      value = params[:min_count].to_i
      value.positive? ? value : DEFAULT_MIN_COUNT
    end

    def applied_filters
      {
        season_id: season_id,
        league_id: league_id&.to_i,
        tag_id: tag_id&.to_i,
        from: from_date&.iso8601,
        to: to_date&.iso8601,
        result: result_filter,
        min_count: min_count
      }
    end

    # --- Export ---------------------------------------------------------------

    EXPORT_HEADERS = ['Schiedsrichter', 'Lizenznummer', 'Anzahl', 'Ø Spielleitung',
                      'Ø Kommunikation', 'Ø Spielleitung Vorperiode', 'Trend Spielleitung',
                      'Trend Kommunikation', 'Top-Gruppe', 'Gespann-Partner'].freeze

    def export_row(referee)
      [
        referee[:referee_name], referee[:lizenznummer], referee[:count],
        referee[:avg_line_rating], referee[:avg_communication_rating],
        referee[:avg_line_rating_prev], referee[:trend_line], referee[:trend_communication],
        referee[:in_group] ? 'ja' : 'nein', referee[:partners].join(', ')
      ]
    end

    def referees_csv(referees)
      CSV.generate(headers: true) do |csv|
        csv << EXPORT_HEADERS
        referees.each { |r| csv << export_row(r) }
      end
    end

    def referees_xlsx(referees)
      package = Axlsx::Package.new
      package.workbook.add_worksheet(name: 'Schiri-Feedback') do |sheet|
        sheet.add_row EXPORT_HEADERS
        referees.each { |r| sheet.add_row export_row(r) }
      end
      package.to_stream.read
    end

    def export_filename(extension)
      "schiri-feedback-auswertung.#{extension}"
    end
  end
end
