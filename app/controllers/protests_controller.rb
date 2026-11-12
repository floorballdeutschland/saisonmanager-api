# frozen_string_literal: true

# Upload des Protestformulars über den Link aus der Mail an eine Protestpartei
# (GameProtestInviter), ohne Anmeldung.
#
# Der Token gilt für genau einen Protest. Die Antwort gibt deshalb nur die
# Kopfdaten dieses einen Spiels heraus. Gegen das Durchprobieren von Tokens
# greift ein IP-Throttle (config/initializers/rack_attack.rb).
class ProtestsController < ApplicationController
  skip_before_action :authenticate_user

  INVALID_MESSAGE = 'Dieser Link ist ungültig.'

  # GET /api/v2/protests/:token
  def show
    protest = GameProtest.find_by_token(params[:token])
    return render json: { message: INVALID_MESSAGE }, status: :gone if protest.nil?

    render json: protest_json(protest)
  end

  # POST /api/v2/protests/:token  (multipart, Feld `file`)
  def create
    protest = GameProtest.find_by_token(params[:token])
    return render json: { message: INVALID_MESSAGE }, status: :gone if protest.nil?

    if protest.submitted?
      return render json: { message: 'Über diesen Link wurde bereits ein Protestformular hochgeladen.' },
                    status: :unprocessable_entity
    end
    if params[:file].blank?
      return render json: { message: 'Bitte wähle das ausgefüllte Protestformular als PDF aus.' },
                    status: :unprocessable_entity
    end

    protest.file.attach(params[:file])
    protest.submitted_at = Time.current
    if protest.save
      notify_sbk(protest)
      render json: protest_json(protest), status: :created
    else
      render json: { message: protest.errors.full_messages.join(' ') }, status: :unprocessable_entity
    end
  end

  private

  def protest_json(protest)
    game = protest.game
    {
      status: protest.submitted? ? 'submitted' : 'open',
      party_label: protest.party_label,
      submitted_at: protest.submitted_at&.iso8601,
      filename: protest.file.attached? ? protest.file.filename.to_s : nil,
      game_number: game.game_number,
      home_team: game.home_team&.name,
      guest_team: game.guest_team&.name,
      league: game.league&.name,
      date: game.game_day&.date,
      start_time: game.start_time
    }
  end

  # Der Upload ist gespeichert; eine scheiternde Mail darf ihn nicht als Fehler
  # zurückmelden. Ohne SBK-Adresse geht das Formular wie das Berichtsformular
  # an das Ansetzungs-Postfach statt nirgends.
  def notify_sbk(protest)
    sa = protest.game.state_association
    sbk_email = sa&.effective_sbk_email.presence
    unless sbk_email
      Rails.logger.warn("Protest: keine SBK-Adresse (Spiel #{protest.game_id}), geht an #{RefereeMailer::REPLY_TO}")
      sbk_email = RefereeMailer::REPLY_TO
    end
    GameMailer.protest_submitted_to_sbk(protest, sbk_email).deliver_later
  rescue StandardError => e
    Rails.logger.warn("Protest-Mail an die SBK fehlgeschlagen (Spiel #{protest.game_id}): #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end
end
