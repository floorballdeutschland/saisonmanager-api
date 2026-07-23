module Admin
  # Übergreifender Feed der Feedback-Freitextkommentare plus manuelles Taggen mit
  # Themen und deren Auswertung (#182). Sichtbarkeit wie das Feedback selbst:
  # Admin sowie die globalen FD-Rollen (RSK/Ansetzer). Ausgeblendete
  # Rückmeldungen (status = 'hidden') bleiben außen vor.
  class FeedbackCommentsController < ApplicationController
    include FeedbackVisibility

    before_action :authorize_feedback_access!

    # GET /api/v2/admin/feedback_comments
    # Feed aller kommentierten Rückmeldungen, filterbar nach Schiri, Top-Gruppe
    # (Tag), Liga, Saison, Zeitraum, Notenschwelle und Thema.
    def index
      render json: feed.map { |feedback| comment_json(feedback) }
    end

    # PATCH /api/v2/admin/feedback_comments/:id/themes
    # Setzt die Themen-Tags einer Rückmeldung (theme_ids ersetzt die bisherigen).
    def update
      feedback = RefereeFeedback.find(params[:id])
      sync_themes(feedback, requested_theme_ids)
      render json: comment_json(feedback.reload)
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    # GET /api/v2/admin/feedback_comments/stats
    # Themen-Häufigkeiten (gesamt, optional Top-Gruppe, per referee_id auch je
    # Schiri) als Ranking plus Monats-Zeitreihe je Thema.
    def stats
      feedbacks = filtered_feedbacks
      group_ids = group_referee_ids
      render json: {
        filters: applied_filters,
        themes: theme_frequencies(feedbacks, group_ids),
        time_series: theme_time_series(feedbacks)
      }
    end

    private

    # --- Feed -----------------------------------------------------------------

    def feed
      base_feedbacks.order(created_at: :desc).to_a
                    .select { |f| within_date_range?(f) }
                    .select { |f| within_rating_threshold?(f) }
    end

    def base_feedbacks
      rel = RefereeFeedback.visible.with_comment
                           .joins(game: { game_day: :league })
                           .includes(:team, :referee1, :referee2, :feedback_themes, game: { game_day: :league })
      rel = rel.where(leagues: { season_id: season_id }) if season_id.present?
      rel = rel.where(leagues: { id: league_id }) if league_id.present?
      rel = rel.for_referee(referee_id) if referee_id.present?
      if theme_id.present?
        rel = rel.where(id: FeedbackThemeTagging.where(feedback_theme_id: theme_id).select(:referee_feedback_id))
      end
      filter_by_group(rel)
    end

    def within_rating_threshold?(feedback)
      return true if max_rating.nil?

      [feedback.line_rating, feedback.communication_rating].min <= max_rating
    end

    # --- Tagging --------------------------------------------------------------

    def sync_themes(feedback, theme_ids)
      feedback.feedback_theme_taggings.where.not(feedback_theme_id: theme_ids).destroy_all
      existing = feedback.feedback_theme_taggings.pluck(:feedback_theme_id)
      (theme_ids - existing).each do |id|
        feedback.feedback_theme_taggings.create!(feedback_theme_id: id, tagged_by_user_id: current_user.id)
      end
    end

    # Nur gültige, existierende Themen-IDs zulassen (kein FK-Fehler durch
    # willkürliche Werte).
    def requested_theme_ids
      Array(params[:theme_ids]).map(&:to_i) & FeedbackTheme.pluck(:id)
    end

    # --- Themen-Auswertung ----------------------------------------------------

    def filtered_feedbacks
      rel = RefereeFeedback.visible
                           .joins(game: { game_day: :league })
                           .includes(:referee1, :referee2, :feedback_themes, game: { game_day: :league })
      rel = rel.where(leagues: { season_id: season_id }) if season_id.present?
      rel = rel.where(leagues: { id: league_id }) if league_id.present?
      rel = rel.for_referee(referee_id) if referee_id.present?
      filter_by_group(rel).to_a.select { |f| within_date_range?(f) }
    end

    def theme_frequencies(feedbacks, group_ids)
      counts = Hash.new(0)
      group_counts = Hash.new(0)
      themes = {}
      feedbacks.each do |feedback|
        in_group = group_ids.any? && in_group?(feedback, group_ids)
        feedback.feedback_themes.each do |theme|
          themes[theme.id] ||= theme
          counts[theme.id] += 1
          group_counts[theme.id] += 1 if in_group
        end
      end

      themes.values.map do |theme|
        {
          theme_id: theme.id,
          name: theme.name,
          color: theme.color,
          count: counts[theme.id],
          group_count: group_ids.any? ? group_counts[theme.id] : nil
        }
      end.sort_by { |entry| [-entry[:count], entry[:name].to_s] }
    end

    def theme_time_series(feedbacks)
      by_period = Hash.new { |hash, key| hash[key] = Hash.new(0) }
      feedbacks.each do |feedback|
        period = game_date(feedback)&.strftime('%Y-%m')
        next if period.nil?

        feedback.feedback_themes.each { |theme| by_period[period][theme.id] += 1 }
      end

      by_period.sort_by { |period, _| period }.map { |period, counts| { period: period, counts: counts } }
    end

    # --- Gemeinsame Filter/Helfer --------------------------------------------

    def filter_by_group(relation)
      return relation if tag_id.blank?

      ids = group_referee_ids.to_a
      relation.where('referee1_id IN (?) OR referee2_id IN (?)', ids, ids)
    end

    def group_referee_ids
      return [] if tag_id.blank?

      RefereeTagging.where(referee_tag_id: tag_id).pluck(:referee_id).to_set
    end

    def in_group?(feedback, group_ids)
      group_ids.include?(feedback.referee1_id) || group_ids.include?(feedback.referee2_id)
    end

    def within_date_range?(feedback)
      return true unless from_date || to_date

      date = game_date(feedback)
      return false if date.nil?
      return false if from_date && date < from_date
      return false if to_date && date > to_date

      true
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

    def comment_json(feedback)
      game = feedback.game
      {
        id: feedback.id,
        game_id: feedback.game_id,
        game_number: game&.game_number,
        date: game&.game_day&.date,
        league: game&.league&.name,
        team_name: feedback.team&.name,
        referee_names: feedback.referee_names,
        referee1_id: feedback.referee1_id,
        referee2_id: feedback.referee2_id,
        line_rating: feedback.line_rating,
        line_comment: feedback.line_comment,
        communication_rating: feedback.communication_rating,
        communication_comment: feedback.communication_comment,
        general_comment: feedback.general_comment,
        status: feedback.status,
        created_at: feedback.created_at.iso8601,
        themes: feedback.feedback_themes.map { |theme| { id: theme.id, name: theme.name, color: theme.color } }
      }
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

    def referee_id
      params[:referee_id].presence
    end

    def theme_id
      params[:theme_id].presence
    end

    def max_rating
      params[:max_rating].present? ? params[:max_rating].to_i : nil
    end

    def from_date
      return @from_date if defined?(@from_date)

      @from_date = parse_date(params[:from])
    end

    def to_date
      return @to_date if defined?(@to_date)

      @to_date = parse_date(params[:to])
    end

    def applied_filters
      {
        season_id: season_id,
        league_id: league_id&.to_i,
        tag_id: tag_id&.to_i,
        referee_id: referee_id&.to_i,
        from: from_date&.iso8601,
        to: to_date&.iso8601
      }
    end
  end
end
