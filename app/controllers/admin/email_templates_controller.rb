module Admin
  # CRUD-Lite für admin-pflegbare E-Mail-Vorlagen: Liste aller code-definierten
  # Templates (Katalog) zusammengeführt mit gepflegten Überschreibungen, plus ein
  # Update-Endpoint. Keys sind code-definiert → kein Create/Destroy nach außen.
  class EmailTemplatesController < ApplicationController
    before_action :require_admin!

    # GET /api/v2/admin/email_templates
    def index
      saved = EmailTemplate.all.index_by { |t| [t.mailer_class, t.action_name, t.locale] }
      result = EmailTemplateCatalog.entries.map do |entry|
        template = saved[[entry[:mailer_class], entry[:action_name], EmailTemplate::DEFAULT_LOCALE]]
        serialize(entry, template)
      end
      render json: result
    end

    # PATCH /api/v2/admin/email_templates
    def update
      attrs = email_template_params
      entry = EmailTemplateCatalog.find(attrs[:mailer_class], attrs[:action_name])
      return render json: { error: 'Unbekannte Vorlage' }, status: :unprocessable_entity if entry.nil?

      locale = attrs[:locale].presence || EmailTemplate::DEFAULT_LOCALE
      template = EmailTemplate.find_or_initialize_by(
        mailer_class: attrs[:mailer_class], action_name: attrs[:action_name], locale: locale
      )
      template.assign_attributes(attrs.slice(:subject, :from_address, :reply_to_address))

      # Vollständig leere Anpassung → Datensatz entfernen (zurück auf Code-Default).
      if template.subject.blank? && template.from_address.blank? && template.reply_to_address.blank?
        template.destroy if template.persisted?
        return render json: serialize(entry, nil)
      end

      if template.save
        render json: serialize(entry, template)
      else
        render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
      end
    end

    private

    def serialize(entry, template)
      {
        key: "#{entry[:mailer_class]}##{entry[:action_name]}",
        mailer_class: entry[:mailer_class],
        action_name: entry[:action_name],
        description: entry[:description],
        placeholders: entry[:placeholders],
        default_subject: entry[:default_subject],
        default_from: entry[:default_from],
        default_reply_to: entry[:default_reply_to],
        subject: template&.subject,
        from_address: template&.from_address,
        reply_to_address: template&.reply_to_address,
        customized: template.present?
      }
    end

    def email_template_params
      params.require(:email_template).permit(:mailer_class, :action_name, :locale,
                                             :subject, :from_address, :reply_to_address)
    end

    def require_admin!
      return if current_user.permission_hash[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
