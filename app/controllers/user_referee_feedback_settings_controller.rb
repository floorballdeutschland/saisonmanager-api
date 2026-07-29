# frozen_string_literal: true

# Einstellung je Mannschaft, wer das Schiri-Feedback abgibt (TM/VM).
#
# Die Werte hängen bewusst an der Mannschaft und nicht am Benutzerkonto: Hat eine
# Mannschaft mehrere Teammanager, sehen und bearbeiten alle denselben Eintrag.
# feedback_contact_updated_by/_at halten fest, wer ihn zuletzt geändert hat.
class UserRefereeFeedbackSettingsController < ApplicationController
  include ManagedTeams

  before_action :authenticate_user

  # GET /api/v2/user/referee_feedback_settings
  def index
    return render json: [] if managed_team_ids.empty?

    render json: settings_teams.map { |team| team_settings_json(team) }
  end

  # PATCH /api/v2/user/referee_feedback_settings/:id  (id = team_id)
  def update
    team = Team.find(params[:id])
    return render json: { error: 'Nicht berechtigt' }, status: :forbidden unless managed_team_ids.include?(team.id)

    email = params[:feedback_contact_email].to_s.strip
    if params.key?(:feedback_contact_email) && email.present? && !email.match?(URI::MailTo::EMAIL_REGEXP)
      return render json: { error: 'Bitte eine gültige E-Mail-Adresse angeben.' }, status: :unprocessable_entity
    end

    team.update!(changed_settings.merge(
                   feedback_contact_updated_at: Time.current,
                   feedback_contact_updated_by: current_user.id
                 ))

    render json: team_settings_json(team)
  end

  private

  # Nur mitgeschickte Felder anfassen. Sonst würde ein Aufruf, der allein die
  # Kapitäns-Einstellung setzt, die hinterlegte Adresse löschen (und umgekehrt),
  # und die Antwort meldete die Löschung als Erfolg.
  def changed_settings
    attrs = {}
    attrs[:feedback_contact_email] = params[:feedback_contact_email].to_s.strip.presence if
      params.key?(:feedback_contact_email)
    if params.key?(:feedback_contact_prefer_captain)
      attrs[:feedback_contact_prefer_captain] =
        ActiveModel::Type::Boolean.new.cast(params[:feedback_contact_prefer_captain]).present?
    end
    attrs
  end

  # Nur Mannschaften, die in einer feedback-pflichtigen Liga der aktuellen Saison
  # spielen (inkl. Pokal-/Zusatzligen über Team#all_league_ids) – analog zum
  # Menü-Gate User#manages_referee_feedback_team?. Ohne den Saison-Filter
  # tauchten Mannschaften vergangener Saisons in der Einstellung auf.
  def settings_teams
    enabled_league_ids = League.current_season.where(referee_feedback_enabled: true).pluck(:id)
    return [] if enabled_league_ids.empty?

    Team.where(id: managed_team_ids)
        .order(:name)
        .select { |team| (team.all_league_ids & enabled_league_ids).any? }
  end

  def team_settings_json(team)
    {
      team_id: team.id,
      team_name: team.name,
      feedback_contact_email: team.feedback_contact_email,
      feedback_contact_prefer_captain: team.feedback_contact_prefer_captain,
      updated_at: team.feedback_contact_updated_at&.iso8601,
      updated_by: User.find_by(id: team.feedback_contact_updated_by)&.fullname
    }
  end
end
