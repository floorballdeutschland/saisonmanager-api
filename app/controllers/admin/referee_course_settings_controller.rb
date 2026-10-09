module Admin
  # Schalter fuer die Kursprozesse in den Schiri-Einstellungen: CSV-Import der
  # Kursergebnisse an/aus und Kurse im System an/aus (optional nur fuer einzelne
  # Landesverbaende). Gespeichert in Setting#referee_course_processes, gelesen
  # ueber Setting.referee_course_csv_import_enabled? und
  # Setting.referee_courses_enabled?.
  #
  # Der Import-Schalter sperrt nur NEUE Uploads. Bereits hochgeladene Zeilen
  # bleiben bearbeitbar und einreichbar, und die LV-Freigabe laeuft weiter --
  # sonst blieben beim Abschalten offene Reviews haengen.
  class RefereeCourseSettingsController < ApplicationController
    before_action :authorize_admin!

    # GET /api/v2/admin/referee_course_settings
    def show
      render json: settings_json
    end

    # PATCH /api/v2/admin/referee_course_settings
    def update
      attrs = params.require(:referee_course_settings)
      processes = Setting.referee_course_processes.except('updated_by_user_id', 'updated_at')

      %w[csv_import_enabled courses_enabled].each do |key|
        next unless attrs.key?(key)

        processes[key] = ActiveModel::Type::Boolean.new.cast(attrs[key]) == true
      end

      if attrs.key?(:courses_state_association_ids)
        ids = Array(attrs[:courses_state_association_ids]).compact_blank.map(&:to_i).uniq.sort
        unknown = ids - StateAssociation.where(id: ids).pluck(:id)
        if unknown.any?
          return render json: { error: "Unbekannter Landesverband: #{unknown.join(', ')}" },
                        status: :unprocessable_entity
        end

        processes['courses_state_association_ids'] = ids
      end

      processes['updated_by_user_id'] = current_user.id
      processes['updated_at'] = Time.current.iso8601

      # Eigene Instanz statt `Setting.current`: deren Rueckgabe ist geteilt. Das
      # after_commit am Setting raeumt den Cache fuer alle Worker ab.
      setting = Setting.first
      return render json: { error: 'Keine Einstellungen vorhanden' }, status: :not_found if setting.nil?

      setting.update!(referee_course_processes: processes)
      render json: settings_json
    end

    private

    def settings_json
      processes = Setting.referee_course_processes
      {
        csv_import_enabled: processes['csv_import_enabled'],
        courses_enabled: processes['courses_enabled'],
        courses_state_association_ids: processes['courses_state_association_ids'],
        updated_at: processes['updated_at'],
        updated_by: updated_by_label(processes['updated_by_user_id']),
        # Fuer den Hinweis in der Maske: Solange Zeilen beim Importeur offen
        # sind, bleibt der Menuepunkt „Kursergebnisse" trotz Schalter aus sichtbar.
        open_import_rows: RefereeCourseResult.open_in_active_import.count
      }
    end

    # `fullname` ist bei einem Konto ohne Namen ein Leerzeichen, nicht leer.
    def updated_by_label(user_id)
      user = User.find_by(id: user_id)
      return nil if user.nil?

      user.fullname.strip.presence || user.username
    end

    def authorize_admin!
      return if current_user&.permission_hash&.dig(:admin).present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
