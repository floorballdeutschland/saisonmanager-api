# frozen_string_literal: true

# Nimmt einen Beobachtungsbogen entgegen. Kapselt drei Dinge, die der Controller
# nicht kennen muss: die Auflösung des Gespanns, die Idempotenz (ein Bogen je
# Spiel und Coach) und die Zuordnung zum Spielbetrieb.
#
# Die Berechtigung prüft der Controller über RefereeObservationPolicy, nicht
# dieser Service – wie bei RefereeFeedbackSubmission.
class RefereeObservationSubmission
  NO_REFEREES_ERROR = 'Zu diesem Spiel ist kein Schiedsrichter hinterlegt, ' \
                      'eine Beobachtung kann deshalb niemandem zugeordnet werden.'
  NO_GAME_OPERATION_ERROR = 'Das Spiel gehört zu keinem Spielbetrieb.'
  # Eine eigene deutsche Meldung statt errors.full_messages: Letztere wären
  # englische ActiveRecord-Texte mitten in einer deutschen Maske.
  INVALID_ERROR = 'Bitte alle Bewertungen (1 bis 7) und alle Textfelder ausfüllen.'

  def initialize(game:, coach:, user:, attributes:)
    @game = game
    @coach = coach
    @user = user
    @attributes = attributes
  end

  # Liefert [observation, error]. observation.previously_new_record? zeigt an, ob
  # in diesem Aufruf ein Bogen entstanden ist (201) oder ob bereits einer vorlag (200).
  def call
    existing = RefereeObservation.find_by(game: @game, coach: @coach)
    return [existing, nil] if existing

    go_id = @game.league&.game_operation_id
    return [nil, NO_GAME_OPERATION_ERROR] if go_id.blank?

    referees, names = @game.feedback_referees
    return [nil, NO_REFEREES_ERROR] if referees.empty?

    observation = build(go_id, referees, names)
    return [observation, nil] if observation.save

    # Zwei Geräte gleichzeitig: Die Modell-Validierung auf Einmaligkeit greift vor
    # dem Unique-Index, deshalb landet der zweite Versuch meist hier.
    existing = RefereeObservation.find_by(game: @game, coach: @coach)
    return [existing, nil] if existing

    Rails.logger.warn(
      "RefereeObservationSubmission ungültig: game=#{@game.id} coach=#{@coach.id} " \
      "errors=#{observation.errors.full_messages.join(', ')}"
    )
    [nil, INVALID_ERROR]
  rescue ActiveRecord::RecordNotUnique
    existing = RefereeObservation.find_by(game: @game, coach: @coach)
    return [existing, nil] if existing

    [nil, 'Beobachtung konnte nicht gespeichert werden.']
  end

  private

  def build(go_id, referees, names)
    observation = RefereeObservation.new(
      game: @game,
      coach: @coach,
      referee_assignment: coach_assignment,
      game_operation_id: go_id,
      created_by_user_id: @user&.id,
      coach_name: "#{@coach.vorname} #{@coach.nachname}".strip.presence,
      submitted_at: Time.current
    )
    RefereeObservation::TEXT_ATTRIBUTES.each do |field|
      observation[field] = @attributes[field].to_s.strip.presence
    end
    RefereeObservation::PAIR_RATING_ATTRIBUTES.each do |field|
      observation[field] = rating(@attributes[field])
    end
    build_ratings(observation, referees, names)
    observation
  end

  # Nur die Personen, für die der Bogen auch Bewertungen mitschickt. Ein Gespann
  # kann unvollständig sein (ein Schiri allein), und ein Coach kann bewusst nur
  # eine Person bewerten – dann entsteht auch nur für diese eine Zeile.
  def build_ratings(observation, referees, names)
    referees.each_with_index do |referee, index|
      submitted = referee_attributes(referee.id)
      next if submitted.blank?

      observation.ratings.build(
        referee: referee,
        referee_name: names[index].presence,
        position: index + 1,
        **RefereeObservationRating::RATING_ATTRIBUTES.index_with { |f| rating(submitted[f]) }
      )
    end
  end

  # Die Bewertungen kommen als Liste `ratings: [{ referee_id:, stick_play_rating:, … }]`.
  # Zugriff über die Referee-PK und nicht über die Position, damit ein
  # vertauschter Index nicht die Bewertung der falschen Person speichert.
  def referee_attributes(referee_id)
    @by_referee_id ||= Array(@attributes[:ratings]).each_with_object({}) do |entry, map|
      attrs = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry
      attrs = attrs.symbolize_keys
      map[attrs[:referee_id].to_i] = attrs
    end
    @by_referee_id[referee_id.to_i]
  end

  def coach_assignment
    assignment = @game.referee_assignment
    assignment if assignment&.coach_id == @coach.id
  end

  # Leere Eingaben als nil weiterreichen, damit die Validierung „fehlt" meldet
  # und nicht stillschweigend eine 0 speichert.
  def rating(value)
    return nil if value.blank?

    value.to_i
  end
end
