# Stellt den Mailer-Views die Frontend-Basis-URL bereit, damit E-Mail-Templates
# keine Hosts hartcodieren (sonst zeigen Staging-Mails auf das Produktivsystem).
module MailerHelper
  # `module_function`, damit format_game_day_date auch dort nutzbar ist, wo kein
  # View-Kontext existiert: Betreff und Platzhalter werden im Mailer selbst
  # zusammengebaut, und genau dort scheiterte die Formatierung bisher. In den
  # Vorlagen bleiben die Methoden über den impliziten Empfänger erreichbar.
  module_function

  def frontend_base_url
    FrontendUrl.base
  end

  def frontend_host
    FrontendUrl.host
  end

  # Spieltagsdatum für die Anzeige. Zwei Gründe, warum hier nicht I18n.l steht:
  #
  # 1. game_days.date ist eine Textspalte. I18n.l auf einem String wirft
  #    ArgumentError („Object must be a Date, DateTime or Time object"), die
  #    Vorlage konnte damit überhaupt nicht rendern.
  # 2. Es gibt nur config/locales/en.yml, die Default-Locale ist :en. I18n.l
  #    hätte in einer deutschen Mail ein englisches Datum ausgegeben.
  #
  # Format wie in den übrigen Mail-Vorlagen (strftime('%d.%m.%Y')). Nicht lesbare
  # Werte werden unverändert ausgegeben, statt die ganze Mail zu verlieren –
  # solche Einträge kennt der Datenbestand (vgl. den früheren Invalid-Date-Fehler
  # im Spielplan).
  def format_game_day_date(value)
    return '' if value.blank?
    return value.strftime('%d.%m.%Y') if value.respond_to?(:strftime)

    begin
      Date.parse(value.to_s).strftime('%d.%m.%Y')
    rescue Date::Error
      value.to_s
    end
  end
end
