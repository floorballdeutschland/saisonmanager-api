# frozen_string_literal: true

# Eine YouTube-Übertragung, die der Watchdog beobachtet.
#
# Siehe StreamWatchdog für die Regeln, nach denen eine Übertragung beendet wird,
# und die Migration für den Grund, warum der Zustand in der Datenbank statt in
# einer Datei neben dem Skript liegt.
class StreamBroadcast < ApplicationRecord
  # optional, weil eine Übertragung nicht zwingend an einem Spiel hängt (siehe
  # Migration: Tagesstream einer Deutschen Meisterschaft).
  belongs_to :game, optional: true

  validates :broadcast_id, presence: true, uniqueness: true

  scope :running, -> { where(ended_at: nil) }

  # Versatz zwischen Halle und Bild, gesetzt über die Kalibrierung (fe#560).
  # Spannweite großzügig um die beobachteten 10 bis 30 s; negativ ist erlaubt,
  # falls eine Kamera mit falscher Uhr oder ein später Streamstart das Bild
  # vorlaufen lässt.
  OFFSET_RANGE = (-120..120)
  validates :offset_seconds, numericality: { only_integer: true, in: OFFSET_RANGE }, allow_nil: true

  def calibrated?
    !offset_seconds.nil?
  end

  def ended?
    ended_at.present?
  end

  # Wie lange schon ohne Signal, in Sekunden -- oder nil, solange Signal anliegt.
  def offline_for(now = Time.current)
    signal_lost_at && (now - signal_lost_at)
  end
end
