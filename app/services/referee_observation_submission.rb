# frozen_string_literal: true

# Nimmt einen Beobachtungsbogen entgegen. Kapselt drei Dinge, die der Controller
# nicht kennen muss: die Auflösung des Gespanns, die Idempotenz (ein Bogen je
# Spiel und Coach) und die Zuordnung zum Spielbetrieb.
#
# Auch die nachträgliche Bearbeitung durch den Coach (#update, feedback#74) läuft
# hier durch: Freitexte und Noten werden mit denselben Methoden übernommen und
# mit denselben Modell-Validierungen geprüft wie bei der Abgabe.
#
# Die Berechtigung prüft der Controller über RefereeObservationPolicy, nicht
# dieser Service – wie bei RefereeFeedbackSubmission.
class RefereeObservationSubmission
  NO_REFEREES_ERROR = 'Zu diesem Spiel ist kein Schiedsrichter hinterlegt, ' \
                      'eine Beobachtung kann deshalb niemandem zugeordnet werden.'
  # Gespann eingetragen, aber niemand davon einzeln bewertbar (Gäste, Freitext
  # ohne zugeordnetes Profil). Siehe RefereeObservationCrew.
  NO_RATEABLE_REFEREES_ERROR = 'Im Gespann dieses Spiels ist niemand einem regulären ' \
                               'Schiedsrichterprofil zugeordnet (Gastschiedsrichter werden ' \
                               'nicht einzeln bewertet). Eine Beobachtung ist hier nicht möglich.'
  NO_GAME_OPERATION_ERROR = 'Das Spiel gehört zu keinem Spielbetrieb.'
  # Eine eigene deutsche Meldung statt errors.full_messages: Letztere wären
  # englische ActiveRecord-Texte mitten in einer deutschen Maske.
  INVALID_ERROR = 'Bitte alle Bewertungen (1 bis 7) und alle Textfelder ausfüllen.'

  # Die Bearbeitung nimmt Spiel und Coach aus dem Bogen selbst, nicht aus den
  # Parametern: Ein Bogen wandert dabei weder in ein anderes Spiel noch zu einer
  # anderen Person.
  def self.for_edit(observation, user:, attributes:)
    new(game: observation.game, coach: observation.coach, user: user, attributes: attributes)
  end

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

    crew = RefereeObservationCrew.new(@game)
    return [nil, crew.unrated_names.any? ? NO_RATEABLE_REFEREES_ERROR : NO_REFEREES_ERROR] if crew.empty?

    observation = build(go_id, crew)
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

  # Bearbeitung eines abgegebenen Bogens durch seinen Coach. Liefert
  # [observation, error] wie #call.
  #
  # Bewertet bleiben genau die Personen, die bei der Abgabe bewertet wurden. Das
  # Gespann wird nicht neu aufgelöst: Ein inzwischen geänderter Spielbericht soll
  # keine Bewertung verschwinden lassen, über die die Person schon per Mail
  # informiert wurde. Fehlen für eine dieser Personen Noten, ist der Bogen
  # ungültig wie bei der Abgabe.
  #
  # edited_at wird nur gesetzt, wenn sich wirklich etwas geändert hat; ein
  # unverändert gespeicherter Bogen bekommt keinen Vermerk.
  def update(observation)
    assign_contents(observation)
    observation.ratings.each { |row| assign_ratings(row, referee_attributes(row.referee_id)) }
    return [observation, nil] unless observation.changed? || observation.ratings.any?(&:changed?)

    observation.edited_at = Time.current
    return [observation, nil] if observation.save

    Rails.logger.warn(
      "RefereeObservationSubmission#update ungültig: observation=#{observation.id} " \
      "errors=#{observation.errors.full_messages.join(', ')}"
    )
    [nil, INVALID_ERROR]
  end

  private

  def build(go_id, crew)
    observation = RefereeObservation.new(
      game: @game,
      coach: @coach,
      referee_assignment: coach_assignment,
      game_operation_id: go_id,
      created_by_user_id: @user&.id,
      coach_name: "#{@coach.vorname} #{@coach.nachname}".strip.presence,
      submitted_at: Time.current
    )
    assign_contents(observation)
    build_ratings(observation, crew)
    observation
  end

  # Freitexte und Gespann-Noten, gemeinsam für Abgabe und Bearbeitung.
  def assign_contents(observation)
    RefereeObservation::TEXT_ATTRIBUTES.each do |field|
      observation[field] = @attributes[field].to_s.strip.presence
    end
    RefereeObservation::PAIR_RATING_ATTRIBUTES.each do |field|
      observation[field] = rating(@attributes[field])
    end
  end

  # Einzelnoten einer Person, gemeinsam für Abgabe und Bearbeitung. Ohne
  # mitgeschickte Noten bleiben die Felder leer und die Validierung meldet sie.
  def assign_ratings(row, submitted)
    RefereeObservationRating::RATING_ATTRIBUTES.each do |field|
      row[field] = rating(submitted&.dig(field))
    end
  end

  # Nur die Personen, für die der Bogen auch Bewertungen mitschickt. Ein Gespann
  # kann unvollständig sein (ein Schiri allein), und ein Coach kann bewusst nur
  # eine Person bewerten – dann entsteht auch nur für diese eine Zeile. Gäste
  # stehen gar nicht erst in der Crew (RefereeObservationCrew): Eine
  # mitgeschickte Bewertung für sie wird verworfen.
  def build_ratings(observation, crew)
    crew.entries.each do |entry|
      referee = entry[:referee]
      submitted = referee_attributes(referee.id)
      next if submitted.blank?

      row = observation.ratings.build(
        referee: referee,
        referee_name: entry[:name].presence,
        position: entry[:position]
      )
      assign_ratings(row, submitted)
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
