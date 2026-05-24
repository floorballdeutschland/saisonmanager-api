class ApplicationMailer < ActionMailer::Base
  default from: 'system@saisonmanager.org'
  layout 'mailer'

  before_action :tag_mailer_headers

  private

  def tag_mailer_headers
    headers['X-Mailer-Class'] = self.class.name
    headers['X-Mailer-Action'] = action_name
  end
end
