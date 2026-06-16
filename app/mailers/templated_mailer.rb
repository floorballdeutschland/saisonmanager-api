# Lässt Mailer Betreff, Absender und Reply-To aus einer admin-pflegbaren
# EmailTemplate ziehen. Die Code-Defaults (Betreff-Template, From, Reply-To)
# liefert der EmailTemplateCatalog; existiert ein gepflegter Datensatz, hat er
# Vorrang. Der Body bleibt unverändert das ERB-View (bzw. ein übergebener Block).
#
# Verwendung im Mailer:
#
#   def license_notification(referee)
#     @referee = referee
#     templated_mail(
#       to: referee.email,
#       placeholders: { referee_name: "#{referee.vorname} #{referee.nachname}" }
#     )
#   end
#
# Dynamische, zur Laufzeit berechnete Werte (z. B. Reply-To im Namen der SBK)
# werden über default_reply_to/default_from übergeben und greifen, sofern weder
# ein gepflegter Datensatz noch der Katalog etwas vorgibt.
module TemplatedMailer
  extend ActiveSupport::Concern

  PLACEHOLDER_PATTERN = /\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/

  private

  def templated_mail(placeholders: {}, default_from: nil, default_reply_to: nil, **mail_opts, &block)
    catalog = EmailTemplateCatalog.find(self.class.name, action_name)
    template = EmailTemplate.resolve(self.class.name, action_name)

    subject_template = template&.subject.presence || mail_opts[:subject] || catalog&.dig(:default_subject)
    from = template&.from_address.presence || default_from || catalog&.dig(:default_from)
    reply_to = template&.reply_to_address.presence || default_reply_to || catalog&.dig(:default_reply_to)

    opts = mail_opts.merge(subject: render_placeholders(subject_template.to_s, placeholders))
    opts[:from] = from if from.present?
    opts[:reply_to] = reply_to if reply_to.present?

    mail(opts, &block)
  end

  def render_placeholders(text, placeholders)
    indexed = placeholders.transform_keys { |k| k.to_s.downcase }
    # Betreffzeilen sind kein HTML → kein HTML-Escaping (sonst würde z. B.
    # "Verein & Co" zu "Verein &amp; Co"). Body-Pflege ist Folge-Ausbaustufe.
    text.gsub(PLACEHOLDER_PATTERN) do
      indexed[Regexp.last_match(1).downcase].to_s
    end
  end
end
