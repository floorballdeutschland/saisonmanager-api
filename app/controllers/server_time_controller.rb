# frozen_string_literal: true

# Serverzeit für den Uhrenabgleich des Tabletmodus (api#816, fe#344).
#
# Das Tablet misst beim Start die Abweichung seiner Uhr und rechnet sie aus dem
# Zeitpunkt jedes Antippens heraus. Ganz offen, ohne Anmeldung und ohne
# API-Schlüssel: Die Uhrzeit ist kein Geheimnis, und der Abgleich muss auch im
# Sekretariats-Link vor jeder anderen Anfrage funktionieren. Millisekunden,
# weil die Highlights auf wenige Sekunden genau sein sollen.
class ServerTimeController < ApplicationController
  skip_before_action :authenticate_user

  def show
    response.headers['Cache-Control'] = 'no-store'
    render json: { now: Time.current.utc.iso8601(3) }
  end
end
