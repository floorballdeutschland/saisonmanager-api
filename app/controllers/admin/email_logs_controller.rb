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

      TestMailer.send_test(recipient).deliver_now
      render json: { ok: true }
    end
  end
end
