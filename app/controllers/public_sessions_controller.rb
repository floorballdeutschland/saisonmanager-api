# POST /api/v2/public_session
#
# Stellt der eigenen Website eine anonyme Sitzung aus (PublicSession). Das
# Frontend ruft den Endpunkt auf, sobald ein öffentlicher Abruf mit dem Code
# `public_session_required` abgewiesen wird, und wiederholt den Abruf danach.
#
# Offen für jeden, gedrosselt je Adresse (Throttle 'public-session/ip'). Eine
# noch gültige Sitzung wird weitergeführt statt ersetzt, damit ein wiederholter
# Aufruf nicht nebenbei einen frischen Throttle-Zähler verschafft.
#
# Kein CSRF-Problem: verified_request? lässt Requests ohne Anmeldung durch, und
# der Endpunkt gibt nichts heraus, was ein fremder Aufruf nicht ohnehin bekäme.
class PublicSessionsController < ApplicationController
  skip_before_action :authenticate_user

  def create
    existing = PublicSession.verify(cookies[PublicSession::COOKIE_NAME])
    value, payload = PublicSession.issue(id: existing&.id || SecureRandom.hex(16))
    cookies[PublicSession::COOKIE_NAME] = PublicSession.cookie_options(value)

    render json: { success: true, expires_at: payload.issued_at + PublicSession::TTL }
  end
end
