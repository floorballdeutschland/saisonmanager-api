module Admin
  # Pflege der Links auf externe Informationsblätter (floorball.de), die das
  # Frontend an festen Stellen anbietet – z. B. das Datenschutz-Informationsblatt
  # für minderjährige Bundesligaspieler*innen im Lizenzantrag. Die Links liegen
  # als JSONB-Hash in Setting#info_links, keyed by Setting::INFO_LINK_KEYS.
  #
  # Angezeigt wird die Verwaltung im Dokumentarten-Katalog
  # (/verwaltung/dokumentarten) und folgt dessen Rechte-Semantik: Lesen dürfen
  # Admin und SBK, ändern nur Admin und die bundesweite SBK (SBK FD).
  # Neue Keys werden im Code angelegt (sie brauchen ohnehin einen Aufrufer im
  # Frontend); über die API ist nur die URL änderbar.
  class InfoLinksController < ApplicationController
    before_action :authorize_read!, only: :index
    before_action :authorize_manage!, only: :update

    # GET /api/v2/admin/info_links
    def index
      render json: Setting::INFO_LINK_KEYS.map { |key| link_json(key) }
    end

    # PATCH /api/v2/admin/info_links/:id  (id = Key)
    def update
      key = params[:id].to_s
      return render json: { error: 'Unbekannter Link-Schlüssel' }, status: :not_found unless
        Setting::INFO_LINK_KEYS.include?(key)

      # Eine leere Adresse entfernt den Link – deshalb darf ein Request, der gar
      # keine Adresse mitbringt, nicht als „entfernen" durchgehen. Sonst löscht
      # ein falsch geformter Aufruf (fehlende oder verschriebene Wurzel, Skalar
      # statt Hash) die gepflegte Adresse still und antwortet dabei mit 200.
      info_link = params[:info_link]
      unless info_link.is_a?(ActionController::Parameters) && info_link.key?(:url)
        return render json: { error: 'Es wurde keine Adresse übermittelt (info_link[url] fehlt).' },
                      status: :unprocessable_entity
      end

      url = info_link[:url].to_s.strip
      error = validation_error(url)
      return render json: { error: error }, status: :unprocessable_entity if error

      persist(key, url)

      render json: link_json(key)
    end

    private

    def link_json(key)
      { key: key, url: Setting.info_link_url(key) }
    end

    # Leer ist erlaubt: So lässt sich ein Link entfernen, solange keine gültige
    # Adresse vorliegt (das Frontend blendet ihn dann aus).
    def validation_error(url)
      return nil if url.blank?
      return 'Der Link ist zu lang (maximal 500 Zeichen).' if url.length > 500

      # URI.parse verträgt keine Nicht-ASCII-Zeichen und wirft dort
      # InvalidURIError. floorball.de legt Dateien mit Umlauten im Namen ab
      # („Info-Übersicht.pdf") – ohne die escapte Kopie liesse sich genau die
      # Adresse nicht hinterlegen, um die es hier geht. Geprüft wird die Kopie,
      # gespeichert die Eingabe: Browser kodieren beim Aufruf selbst, und eine
      # doppelt escapte Adresse führte ins Leere.
      uri = URI.parse(URI::DEFAULT_PARSER.escape(url))
      return 'Der Link muss mit http:// oder https:// beginnen.' unless uri.is_a?(URI::HTTP) && uri.host.present?

      nil
    rescue URI::InvalidURIError
      'Der Link ist keine gültige Web-Adresse.'
    end

    # JSONB wird nur als geändert erkannt, wenn das Attribut neu zugewiesen wird –
    # In-Place-Mutation des Hash persistiert nicht zuverlässig (vgl. penalty_codes).
    def persist(key, url)
      setting = Setting.current
      links = (setting.info_links || {}).deep_dup
      if url.blank?
        links.delete(key)
      else
        # Fremdformat (blanker String statt Hash, etwa aus der Konsole) nicht
        # mergen wollen – sonst NoMethodError statt einer gespeicherten Adresse.
        existing = links[key]
        existing = {} unless existing.is_a?(Hash)
        links[key] = existing.merge('url' => url)
      end
      setting.info_links = links
      setting.save!
    end

    def authorize_read!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Gleiche Semantik wie Admin::DocumentTypesController#authorize_manage!.
    def authorize_manage!
      ph = current_user.permission_hash
      return if ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0))

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
