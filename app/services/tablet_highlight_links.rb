# frozen_string_literal: true

# Verschickt die Links zum Kalibrieren und Auswählen der Highlights (fe#560),
# sobald die Aufzeichnung eines Spiels fertig ist, und räumt verfallene
# Anfragen weg.
#
# LÄUFT IM WÄCHTER MIT (StreamWatchdog#run, Fünf-Minuten-Cronjob), hinter den
# Sprungmarken. Fertig heißt: Es gibt eine öffentlich verlinkte Übertragung mit
# bekanntem Start und bekannter Länge (StreamTimeline#ready?). Die Länge
# speichert StreamChapters erst, wenn YouTube die Aufzeichnung verarbeitet hat,
# und StreamChapters läuft nur für Spiele mit abgeschlossenem Bericht. Vorher
# wartet die Anfrage.
#
# `deliver_now`: Der Wächter läuft als Rake-Task; eine eingereihte Mail ginge
# mit dem Ende des Prozesses verloren.
#
# GENAU EINMAL: Beanspruchen und Versand stehen in EINER Transaktion
# (TabletHighlightRequest#claim!). Ein paralleler Lauf (langsamer Wächterlauf,
# Handstart) wartet auf die Zeile und findet sie danach verschickt. Scheitert
# der Versand, rollt alles zurück, auch das Löschen der Adresse; der nächste
# Lauf schickt denselben Link (der Rohtoken ist wiederholbar). Nach
# MAX_SEND_ATTEMPTS Fehlversuchen wird die Anfrage verworfen und gemeldet.
class TabletHighlightLinks
  attr_reader :notes, :probleme, :sent

  def initialize(dry_run: false, now: Time.current)
    @dry_run = dry_run
    @now = now
    @notes = []
    @probleme = []
    @sent = []
  end

  def run
    aufraeumen
    TabletHighlightRequest.pending.includes(:game, :user).order(:created_at).each do |anfrage|
      verschicke(anfrage)
    rescue StandardError => e
      fehlversuch(anfrage, e)
    end
    self
  end

  private

  def verschicke(anfrage)
    return unless bereit?(anfrage.game)

    empfaenger = anfrage.recipient
    if empfaenger.blank?
      # Konto ohne Adresse oder Konto gelöscht: Es gibt niemanden mehr.
      anfrage.destroy! unless @dry_run
      return
    end

    if @dry_run
      @notes << "Highlight-Link für Spiel #{anfrage.game_id} wäre verschickt worden."
      return
    end

    verschickt = TabletHighlightRequest.transaction do
      token = anfrage.claim!(@now)
      next false if token.nil?

      TabletHighlightMailer.calibration_link(anfrage.game, empfaenger, token, anfrage.expires_at).deliver_now
      true
    end
    return unless verschickt

    @sent << anfrage.game_id
  end

  # Zählt außerhalb der zurückgerollten Transaktion. Beim letzten Versuch wird
  # die Anfrage gelöscht, mit ihr eine eingegebene Adresse.
  def fehlversuch(anfrage, fehler)
    versuche = anfrage.send_attempts + 1
    if versuche >= TabletHighlightRequest::MAX_SEND_ATTEMPTS
      TabletHighlightRequest.where(id: anfrage.id).delete_all
      problem("Highlight-Link für Spiel #{anfrage.game_id} nach #{versuche} Fehlversuchen verworfen: " \
              "#{fehler.class} #{fehler.message}")
    else
      TabletHighlightRequest.where(id: anfrage.id).update_all(send_attempts: versuche)
      problem("Highlight-Link für Spiel #{anfrage.game_id}, Versuch #{versuche}: #{fehler.class} #{fehler.message}")
    end
  rescue StandardError => e
    problem("Highlight-Link für Spiel #{anfrage.game_id}: Fehlversuch nicht vermerkt: #{e.class} #{e.message}")
  end

  # Wie StreamChapters#problem: in die Notizen (der Rake-Task schreibt sie nach
  # stderr) und in die Problemliste (Exit-Code, Sentry).
  def problem(text)
    @notes << "PROBLEM: #{text}"
    @probleme << text unless @dry_run
  end

  def bereit?(game)
    @bereit ||= {}
    return @bereit[game.id] if @bereit.key?(game.id)

    broadcast = HighlightEditor.new(game).broadcast
    @bereit[game.id] = broadcast.present? && StreamTimeline.new(game, broadcast).ready?
  end

  def aufraeumen
    return if @dry_run

    TabletHighlightRequest.pending.where(created_at: ...(@now - TabletHighlightRequest::PENDING_MAX_AGE)).delete_all
    TabletHighlightRequest.where(expires_at: ...(@now - TabletHighlightRequest::EXPIRED_RETENTION)).delete_all
  end
end
