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
#
# ERSATZWEG ÜBER DAS TABLET-KONTO: Hat beim Beenden des Tabletmodus niemand
# einen Link angefordert, käme sonst nie jemand außer Admin und SBK zum
# Kalibrieren. Deshalb legt der Lauf vor dem Versand für jedes Tablet-Spiel,
# dessen öffentliche Aufzeichnung fertig ist (wie oben), das noch nicht
# kalibriert ist und für das es keine einzige Anfrage gibt (offen oder
# verschickt), Anfragen für die Konten an, mit denen am Tablet erfasst wurde:
# `game_shots.created_by`, also das angemeldete Konto oder beim
# Spielsekretariats-Link das Konto, das den Link ausgestellt hat
# (GameShotsController, `secretary_or_current_user_id`). Nur nicht archivierte
# Konten mit Adresse, die mit den meisten Einträgen zuerst, höchstens
# MAX_PENDING_PER_GAME. Sie gehen im selben Lauf über den normalen Weg raus,
# mit eigenem Mailtext. Wer den Link bekommt, kann damit auch Szenen ändern;
# das ist gewollt, er hat sie ja erfasst.
#
# Der Ersatzweg greift je Übertragung HÖCHSTENS EINMAL: `highlight_fallback_at`
# wird gesetzt, sobald er geprüft ist, auch wenn es niemanden zum Anschreiben
# gab (dann steht ein Hinweis in den Notizen). Die Anfragen selbst verschwinden
# später (PENDING_MAX_AGE, EXPIRED_RETENTION), "keine Anfrage" allein ginge
# also nach Wochen erneut raus. Nur Aufzeichnungen, die vor höchstens
# PENDING_MAX_AGE begonnen haben, kommen in Frage; ältere Spiele bekommen beim
# Ausrollen keine Post mehr.
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
    ersatz_an_tablet_konten
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

      TabletHighlightMailer.calibration_link(anfrage.game, empfaenger, token, anfrage.expires_at,
                                             fallback: anfrage.fallback).deliver_now
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
    fertige_uebertragung(game).present?
  end

  # Die Übertragung, die auch Highlights und Editor nehmen, wenn sie fertig
  # ist, sonst nil.
  def fertige_uebertragung(game)
    @fertig ||= {}
    return @fertig[game.id] if @fertig.key?(game.id)

    broadcast = HighlightEditor.new(game).broadcast
    @fertig[game.id] = (broadcast if broadcast.present? && StreamTimeline.new(game, broadcast).ready?)
  end

  def ersatz_an_tablet_konten
    ersatz_kandidaten.each do |game|
      ersatz_fuer(game)
    rescue StandardError => e
      problem("Highlight-Link-Ersatz für Spiel #{game.id}: #{e.class} #{e.message}")
    end
  end

  # Grobe Vorauswahl in der Datenbank, damit der Fünf-Minuten-Lauf nicht jedes
  # Tablet-Spiel durchrechnet. Ob die gefundene Übertragung die maßgebliche
  # ist, entscheidet erst #ersatz_fuer.
  def ersatz_kandidaten
    game_ids = StreamBroadcast.where(highlight_fallback_at: nil, calibrated_at: nil)
                              .where(actual_start_at: (@now - TabletHighlightRequest::PENDING_MAX_AGE)..)
                              .where('stream_broadcasts.vod_duration_seconds > 0')
                              .where.not(game_id: nil)
                              .where.not(game_id: TabletHighlightRequest.select(:game_id))
                              .distinct.pluck(:game_id)
    return [] if game_ids.empty?

    Game.where(id: game_ids).where.not(tablet_capture_at: nil).order(:id).to_a
  end

  def ersatz_fuer(game)
    broadcast = fertige_uebertragung(game)
    return if broadcast.nil? || broadcast.calibrated_at.present? || broadcast.highlight_fallback_at.present?
    return if broadcast.actual_start_at < @now - TabletHighlightRequest::PENDING_MAX_AGE

    empfaenger = tablet_empfaenger(game)
    if @dry_run
      @notes << "Highlight-Link für Spiel #{game.id} ginge ersatzweise an die Tablet-Konten " \
                "(#{empfaenger.size})."
      return
    end

    angelegt = TabletHighlightRequest.transaction do
      # Wie TabletHighlightRequest#claim!: Ein paralleler Lauf wartet auf die
      # Zeile und findet den Vermerk danach gesetzt.
      next false if StreamBroadcast.where(id: broadcast.id, highlight_fallback_at: nil)
                                   .update_all(highlight_fallback_at: @now, updated_at: @now) != 1

      empfaenger.each { |user| TabletHighlightRequest.create!(game: game, user: user, fallback: true) }
      true
    end
    return unless angelegt && empfaenger.empty?

    @notes << "Highlight-Link für Spiel #{game.id}: niemand angefordert, und kein Tablet-Konto mit Adresse. " \
              'Kalibrieren nur über Admin oder SBK.'
  end

  # Die Konten, mit denen am Tablet erfasst wurde, die mit den meisten
  # Einträgen zuerst (bei Gleichstand die kleinere id).
  def tablet_empfaenger(game)
    eintraege = GameShot.where(game_id: game.id).where.not(created_by: nil).group(:created_by).count
    return [] if eintraege.empty?

    User.not_archived.where(id: eintraege.keys).to_a
        .select { |user| user.email.present? }
        .sort_by { |user| [-eintraege[user.id], user.id] }
        .first(TabletHighlightRequest::MAX_PENDING_PER_GAME)
  end

  def aufraeumen
    return if @dry_run

    TabletHighlightRequest.pending.where(created_at: ...(@now - TabletHighlightRequest::PENDING_MAX_AGE)).delete_all
    TabletHighlightRequest.where(expires_at: ...(@now - TabletHighlightRequest::EXPIRED_RETENTION)).delete_all
  end
end
