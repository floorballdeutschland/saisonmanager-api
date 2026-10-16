# frozen_string_literal: true

require 'digest'

# Schreibt die Tore eines gestreamten Spiels als Sprungmarken in die
# Beschreibung der YouTube-Aufzeichnung (api#815):
#
#   Sprungmarken zu den Toren (automatisch aus dem Saisonmanager):
#   0:00 Streamstart
#   17:12 1:0 Müller (Schmidt)
#   22:42 2:0 Weber
#   (Ende der Sprungmarken)
#
# LÄUFT IM WÄCHTER MIT (StreamWatchdog#run), also im vorhandenen
# Fünf-Minuten-Cronjob `rake streaming:watchdog`; eine eigene Crontab-Zeile
# braucht es nicht.
#
# WELCHE ÜBERTRAGUNGEN: beendet, einem Spiel zugeordnet, Spielbericht
# `match_record_closed` oder `finalized`, Ende nicht länger als MAX_AGE her. Nach
# dem Abschluss korrigieren Admin und SBK noch, deshalb läuft es bis zum
# Freigeben und darüber hinaus bis MAX_AGE weiter. Geschrieben wird nur, wenn
# sich der Markenblock geändert hat (`chapters_digest`); der Normalfall eines
# Laufs kostet damit kein Kontingent.
#
# KONTINGENT: Start und Länge der Aufzeichnung werden einmal je Übertragung
# gelesen (`videos.list`, eine Einheit je 50 Videos) und an `stream_broadcasts`
# gespeichert. Erst ein geänderter Block kostet etwas: eine Einheit für das
# frische Lesen der Beschreibung, 50 für das Schreiben.
#
# NICHT GESCHRIEBEN wird für nachgetragene Berichte: Liegen mindestens
# NACHTRAG_MIN_GOALS Tore mit Eingabezeit als Anker innerhalb von
# NACHTRAG_SPAN, wurde der Bericht offensichtlich in einem Rutsch vom Papier
# übertragen, und `added_at` sagt nichts über den Torzeitpunkt. Tore, die erst
# nach dem Ende der Aufzeichnung eingetragen wurden, fallen schon über die
# Längenprüfung in StreamTimeline heraus.
#
# TORE UND STRAFEN. Strafen haben keinen Schuss, ihr Anker ist immer die
# Eingabezeit mit demselben Vorlauf von 120 s. Liegen Marken weniger als 10 s
# auseinander, werden sie zusammengelegt, das Tor zuerst.
class StreamChapters
  BLOCK_START = 'Sprungmarken zu den Toren (automatisch aus dem Saisonmanager):'
  BLOCK_END = '(Ende der Sprungmarken)'
  BLOCK_PATTERN = /\n*^#{Regexp.escape(BLOCK_START)}$.*?^#{Regexp.escape(BLOCK_END)}$\n?/m

  # YouTube verlangt mindestens 10 s je Kapitel. Zwei Tore kurz hintereinander
  # werden deshalb zu einer Marke zusammengelegt, sonst verschwindet die
  # Kapitelleiste ganz.
  MIN_CHAPTER_GAP = 10

  NACHTRAG_MIN_GOALS = 3
  NACHTRAG_SPAN = 10.minutes

  # Wie lange nach dem Ende einer Übertragung noch geschrieben wird.
  MAX_AGE = 14.days

  # Die Beschreibung fasst bei YouTube 5000 Zeichen, und spitze Klammern weist
  # `videos.update` ab.
  MAX_DESCRIPTION = 5000

  attr_reader :notes, :probleme, :written

  def initialize(api:, dry_run: false, now: Time.current)
    @api = api
    @dry_run = dry_run
    @now = now
    @notes = []
    @probleme = []
    @written = []
  end

  def run
    saetze = kandidaten.to_a
    return self if saetze.empty?

    details_nachladen(saetze)
    saetze.each do |satz|
      verarbeite(satz)
    rescue YoutubeLiveApi::QuotaExceeded => e
      problem("Kontingent erschöpft, Sprungmarken abgebrochen: #{e.message}")
      break
    end
    self
  end

  # Der Markenblock für ein Spiel und eine Übertragung, oder nil, wenn es
  # nichts zu markieren gibt. Öffentlich, damit die Tests und ein Probelauf ihn
  # ohne YouTube sehen.
  def self.block_for(game, broadcast)
    timeline = StreamTimeline.new(game, broadcast)
    return nil unless timeline.ready?

    eintraege = gueltige_eintraege(timeline)
    return nil if eintraege.empty?

    # Eine Marke ist [Sekunde, [[Rang, Text], …]]. Rang 0 Streamstart, 1 Tor,
    # 2 Strafe: Innerhalb einer zusammengelegten Marke steht das Tor vorn.
    marken = [[0, [[0, 'Streamstart']]]]
    eintraege.each do |sekunde, rang, text|
      if sekunde - marken.last[0] < MIN_CHAPTER_GAP
        marken.last[1] << [rang, text]
      else
        marken << [sekunde, [[rang, text]]]
      end
    end

    zeilen = marken.map { |sekunde, texte| "#{StreamTimeline.timestamp(sekunde)} #{marken_zeile(texte)}" }
    [BLOCK_START, *zeilen, BLOCK_END].join("\n")
  end

  # Nach Rang, bei gleichem Rang in der Reihenfolge des Videos.
  def self.marken_zeile(texte)
    texte.each_with_index.sort_by { |(rang, _text), index| [rang, index] }.map { |(_rang, text), _| text }.join(', ')
  end

  # [[Sekunde, Rang, Text], …] in Reihenfolge des Videos, Tore und Strafen.
  #
  # Ein nachgetragener Bericht wird an den Toren erkannt. Er trifft dann auch
  # die Strafen: Deren einziger Anker ist dieselbe Eingabezeit.
  def self.gueltige_eintraege(timeline)
    tore = timeline.goals
    strafen = timeline.penalties
    if nachgetragen?(tore)
      tore = tore.select(&:shot?)
      strafen = []
    end

    game = timeline.game
    eintraege = tore.map { |goal| [goal, 1, marken_text(game, goal.event)] } +
                strafen.map { |strafe| [strafe, 2, strafen_text(game, strafe.event)] }
    gueltige = eintraege.filter_map do |eintrag, rang, text|
      sekunde = timeline.chapter_position(eintrag)
      sekunde && [sekunde, rang, text]
    end
    gueltige.sort_by { |sekunde, rang, _| [sekunde, rang] }
  end

  # "Strafe 2 Min. Weber (KÜRZEL)". Strafart wie auf der öffentlichen
  # Spielseite (`penalty_type_string`, also der eingefrorene `penalty_name`
  # oder der Katalog), der Name nach derselben Regel wie bei den Toren. Das
  # Teamkürzel sagt, wer bestraft wurde, auch wenn kein Spieler dasteht:
  # Strafen gegen Betreuer (Nummer 2001 bis 2005) und Mannschaftsstrafen.
  def self.strafen_text(game, event)
    nummer = event[:number].to_i
    name = if nummer > 2000 && nummer <= 2000 + Game::MAX_COACHES
             'Betreuer'
           else
             kurzname(game.public_lineup_entry(event[:event_team], event[:number]))
           end
    team = event[:event_team] == 'guest' ? game.guest_team : game.home_team
    kuerzel = team&.ticker_short_name.presence
    text = ['Strafe', event[:penalty_type_string].to_s.strip.presence, name].compact.join(' ')
    text = "#{text} (#{kuerzel})" if kuerzel
    text.delete('<>')
  end

  def self.nachgetragen?(tore)
    eingaben = tore.reject(&:shot?).map(&:anchor_at)
    return false if eingaben.size < NACHTRAG_MIN_GOALS

    eingaben.max - eingaben.min < NACHTRAG_SPAN
  end

  # "1:0 Müller (Schmidt)". Der Nachname wie auf der öffentlichen Spielseite,
  # also ohne ihn, wenn er DSGVO-halber weggelassen wird; dann steht der
  # Vorname da. Eigentor und technisches Tor tragen ihre Bezeichnung.
  def self.marken_text(game, event)
    stand = "#{event[:home_goals]}:#{event[:guest_goals]}"
    name = case event[:goal_type]
           when :owngoal then 'Eigentor'
           when :technical then event[:goal_type_string]
           when :not_assigned then nil
           else kurzname(game.public_lineup_entry(event[:event_team], event[:number]))
           end
    vorlage = kurzname(game.public_lineup_entry(event[:event_team], event[:assist]))
    text = [stand, name].compact_blank.join(' ')
    text = "#{text} (#{vorlage})" if name.present? && vorlage.present?
    text.delete('<>')
  end

  def self.kurzname(entry)
    return nil if entry.nil?

    entry['player_name'].to_s.strip.presence || entry['player_firstname'].to_s.strip.presence
  end

  # Ersetzt einen vorhandenen Block, hängt sonst einen an, und nimmt ihn
  # heraus, wenn `block` nil ist. Text außerhalb des Blocks bleibt, wie er ist.
  def self.beschreibung_mit(beschreibung, block)
    ohne = beschreibung.to_s.sub(BLOCK_PATTERN, '').rstrip
    return ohne if block.nil?
    return block if ohne.empty?

    "#{ohne}\n\n#{block}"
  end

  private

  def kandidaten
    StreamBroadcast.joins(:game)
                   .where(games: { game_status: %w[match_record_closed finalized] })
                   .where(ended_at: (@now - MAX_AGE)..@now)
                   .order(:ended_at)
  end

  # Start und Länge für die Sätze, denen sie noch fehlen. Die Länge steht bei
  # YouTube erst nach der Verarbeitung der Aufzeichnung fest; bis dahin meldet
  # sie `P0D`, und der nächste Lauf fragt erneut.
  def details_nachladen(saetze)
    offen = saetze.reject { |satz| satz.actual_start_at.present? && satz.vod_duration_seconds.to_i.positive? }
    return if offen.empty?

    details = @api.videos(offen.map(&:broadcast_id))
    offen.each do |satz|
      werte = details[satz.broadcast_id]
      next if werte.nil?

      satz.actual_start_at = werte[:actual_start_at] if werte[:actual_start_at]
      satz.vod_duration_seconds = werte[:duration_seconds] if werte[:duration_seconds].to_i.positive?
      satz.save! if !@dry_run && satz.changed?
    end
  rescue YoutubeLiveApi::QuotaExceeded
    raise
  rescue YoutubeLiveApi::Error => e
    notiz("Sprungmarken: Videodaten nicht abrufbar (#{e.class}): #{e.message}")
  end

  def verarbeite(satz)
    block = self.class.block_for(satz.game, satz)
    digest = block && Digest::SHA256.hexdigest(block)
    return if digest == satz.chapters_digest
    # Noch nie geschrieben und nichts zu schreiben: kein Aufruf.
    return if block.nil? && satz.chapters_written_at.nil?

    if @dry_run
      notiz("[Probelauf] würde Sprungmarken schreiben: #{satz.broadcast_id}\n#{block}")
      return
    end

    ergebnis = @api.update_description!(satz.broadcast_id) do |beschreibung|
      neu = self.class.beschreibung_mit(beschreibung, block)
      raise YoutubeLiveApi::Error, "Beschreibung zu lang (#{neu.length} Zeichen)" if neu.length > MAX_DESCRIPTION

      neu
    end
    satz.update!(chapters_digest: digest, chapters_written_at: @now)
    @written << { broadcast_id: satz.broadcast_id, result: ergebnis, markers: block.to_s.lines.size - 2 }
    notiz("Sprungmarken (#{ergebnis}): #{satz.broadcast_id}")
  rescue YoutubeLiveApi::QuotaExceeded
    raise
  rescue YoutubeLiveApi::Error, ActiveRecord::ActiveRecordError => e
    # Kein Stempel: Der nächste Lauf versucht es erneut. Sprungmarken sind ein
    # Komfort; ein Fehlschlag darf den Wächter nicht aufhalten, gemeldet wird er
    # trotzdem.
    problem("Sprungmarken für #{satz.broadcast_id} fehlgeschlagen: #{e.class} #{e.message}")
  end

  def notiz(text)
    @notes << text
  end

  def problem(text)
    @notes << "PROBLEM: #{text}"
    @probleme << text unless @dry_run
  end
end
