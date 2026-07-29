# frozen_string_literal: true

# Nimmt eine Schiri-Feedback-Abgabe an, unabhängig davon, ob sie von einem
# angemeldeten Teammanager kommt (UserRefereeFeedbacksController) oder über einen
# Einmal-Link von einer Person ohne Konto (RefereeFeedbackInvitationsController).
#
# Kapselt die Verknüpfung mit dem Gespann, die Herkunft der Abgabe und die
# Idempotenz: Pro Spiel und Mannschaft gibt es genau ein Feedback (Unique-Index
# game_id+team_id), eine zweite Abgabe liefert unverändert die erste zurück.
#
# Die Berechtigung prüfen die Controller, nicht dieser Service.
class RefereeFeedbackSubmission
  REPORT_OPEN_ERROR = 'Feedback ist erst möglich, sobald der Spielbericht abgeschlossen ist.'
  # Bewusst eine eigene deutsche Meldung: errors.full_messages wären hier
  # englische ActiveRecord-Texte („Line rating can't be blank"), und die stünden
  # auf der öffentlichen Abgabeseite mitten in einer deutschen Seite. Beide
  # Validierungen des Modells (Vorhandensein und 1..10) beschreibt dieser Satz.
  INVALID_RATINGS_ERROR = 'Bitte beide Bewertungen mit einem Wert von 1 bis 10 angeben.'

  def initialize(game:, team:, attributes:, submitted_by_user_id: nil,
                 submitted_by_player_id: nil, submitted_by_email: nil)
    @game = game
    @team = team
    @attributes = attributes
    @submitted_by_user_id = submitted_by_user_id
    @submitted_by_player_id = submitted_by_player_id
    @submitted_by_email = submitted_by_email
  end

  # Liefert [feedback, error_message]. feedback.previously_new_record? zeigt an,
  # ob in diesem Aufruf tatsächlich ein Datensatz entstanden ist (201) oder ob
  # bereits einer vorlag (200).
  def call
    existing = RefereeFeedback.find_by(game: @game, team: @team)
    return [existing, nil] if existing
    return [nil, REPORT_OPEN_ERROR] unless @game.match_record_closed?

    feedback = build
    return [feedback, nil] if feedback.save

    # Parallele Abgabe (Teammanager und Kapitän gleichzeitig): Die Modell-
    # Validierung auf Einmaligkeit greift schon vor dem Unique-Index, deshalb
    # landet der Zweite meist hier und nicht im rescue unten. Die erste Abgabe
    # gewinnt, die zweite bekommt sie unverändert zurück.
    existing = RefereeFeedback.find_by(game: @game, team: @team)
    return [existing, nil] if existing

    Rails.logger.warn(
      "RefereeFeedbackSubmission ungültig: game=#{@game.id} team=#{@team.id} " \
      "errors=#{feedback.errors.full_messages.join(', ')}"
    )
    [nil, INVALID_RATINGS_ERROR]
  rescue ActiveRecord::RecordNotUnique => e
    existing = RefereeFeedback.find_by(game: @game, team: @team)
    return [existing, nil] if existing

    Rails.logger.error(
      "RefereeFeedbackSubmission RecordNotUnique ohne bestehende Abgabe: " \
      "game=#{@game.id} team=#{@team.id} #{e.message}"
    )
    [nil, 'Feedback konnte nicht gespeichert werden.']
  end

  private

  def build
    referees, referee_names = @game.feedback_referees

    RefereeFeedback.new(
      game: @game,
      team: @team,
      club_id: @team.club_id,
      submitted_by_user_id: @submitted_by_user_id,
      submitted_by_player_id: @submitted_by_player_id,
      submitted_by_email: @submitted_by_email,
      referee1_id: referees[0]&.id,
      referee2_id: referees[1]&.id,
      referee_names: referee_names.join(' / ').presence,
      line_rating: @attributes[:line_rating],
      line_comment: @attributes[:line_comment].to_s.strip.presence,
      communication_rating: @attributes[:communication_rating],
      communication_comment: @attributes[:communication_comment].to_s.strip.presence,
      general_comment: @attributes[:general_comment].to_s.strip.presence
    )
  end
end
