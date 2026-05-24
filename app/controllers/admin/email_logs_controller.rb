module Admin
  class EmailLogsController < ApplicationController
    before_action :authorize_admin!

    def index
      EmailLog.purge_old
      render json: EmailLog.recent.as_json(only: %i[id recipient cc subject mailer_action sent_at])
    end

    def send_test
      recipient = params[:recipient].to_s.strip
      return render json: { error: 'recipient required' }, status: :unprocessable_entity if recipient.blank?
      unless recipient.match?(URI::MailTo::EMAIL_REGEXP)
        return render json: { error: 'Ungültige E-Mail-Adresse' }, status: :unprocessable_entity
      end

      TestMailer.send_test(recipient).deliver_now
      render json: { ok: true }
    rescue StandardError => e
      Rails.logger.error("EmailLogsController#send_test failed for #{recipient}: #{e.class}: #{e.message}")
      Sentry.capture_exception(e)
      render json: { error: 'E-Mail konnte nicht versendet werden.' }, status: :service_unavailable
    end

    private

    def authorize_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
