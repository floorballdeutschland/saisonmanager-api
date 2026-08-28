# frozen_string_literal: true

# Antwortformat eines Beobachtungsbogens. Eine Stelle für Selfservice und
# Verwaltung, damit die beiden Sichten nicht auseinanderlaufen – und damit die
# Felder nie über `render json: model` ins Netz gehen.
#
# `own_referee_id` schaltet die Sicht der beobachteten Person: Sie sieht die
# gemeinsamen Freitexte, die Bewertung des Gespanns und ihre EIGENEN
# Einzelbewertungen, nicht die ihres Partners. Die Rückmeldung soll die eigene
# Entwicklung tragen, nicht die Benotung einer anderen Person offenlegen.
class RefereeObservationSerializer
  def initialize(observation, own_referee_id: nil)
    @observation = observation
    @own_referee_id = own_referee_id
  end

  def as_json(*)
    game = @observation.game
    league = game&.league

    base.merge(
      game_id: @observation.game_id,
      game_number: game&.game_number,
      date: game&.game_day&.date,
      home_team: game&.home_team&.name,
      guest_team: game&.guest_team&.name,
      league: league&.name,
      league_id: league&.id,
      game_operation_slug: league&.game_operation&.slug,
      ratings: visible_ratings.map { |r| rating_json(r) }
    )
  end

  private

  def base
    {
      id: @observation.id,
      coach_id: @observation.coach_id,
      coach_name: @observation.coach_name,
      status: @observation.status,
      submitted_at: @observation.submitted_at&.iso8601,
      assigned_as_coach: @observation.referee_assignment_id.present?
    }.merge(texts).merge(pair_ratings)
  end

  def texts
    RefereeObservation::TEXT_ATTRIBUTES.index_with { |field| @observation[field] }
  end

  def pair_ratings
    RefereeObservation::PAIR_RATING_ATTRIBUTES.index_with { |field| @observation[field] }
  end

  def visible_ratings
    ratings = @observation.ratings.sort_by { |r| r.position || 0 }
    return ratings if @own_referee_id.nil?

    ratings.select { |r| r.referee_id == @own_referee_id }
  end

  def rating_json(rating)
    {
      referee_id: rating.referee_id,
      referee_name: rating.referee_name,
      position: rating.position
    }.merge(RefereeObservationRating::RATING_ATTRIBUTES.index_with { |field| rating[field] })
  end
end
