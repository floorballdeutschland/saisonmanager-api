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
# mit dem Ende des Prozesses verloren. Die Anfrage gilt erst nach einem
# erfolgreichen Versand als verschickt, ein Fehler versucht es im nächsten Lauf
# erneut.
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
      @probleme << "Highlight-Link für Spiel #{anfrage.game_id}: #{e.class} #{e.message}"
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

    TabletHighlightRequest.transaction do
      token = anfrage.issue_token!(@now)
      TabletHighlightMailer.calibration_link(anfrage.game, empfaenger, token, anfrage.expires_at).deliver_now
    end
    @sent << anfrage.game_id
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
    TabletHighlightRequest.where(expires_at: ...@now).delete_all
  end
end
