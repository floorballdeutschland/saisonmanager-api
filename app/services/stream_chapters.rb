# frozen_string_literal: true

require 'digest'

# Schreibt die Tore eines im Tabletmodus erfassten, gestreamten Spiels als
# Sprungmarken in die
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
# NUR TABLETMODUS: Ohne erfassten Schuss ist die Eingabezeit der
# einzige Anker, und die liegt je nach Sekretariat 1,5 bis über 3 Minuten
# hinter dem Tor, bei Nachträgen noch weiter (Spiel 58679: die meisten Marken
# landeten hinter dem Tor). Spiele ohne `tablet_capture_at` bekommen deshalb
# keinen Block. Ein früher geschriebener wird wieder entfernt, bei frischen
# Aufzeichnungen im nächsten Lauf, bei älteren in der täglichen Nachrechnung.
# Innerhalb eines Tablet-Spiels behalten Tore ohne verknüpften Schuss und
# Strafen die Eingabezeit als Anker.
#
# ENTFERNEN IST GEDECKELT: Jede Entfernung kostet 51 Einheiten. Nach dem
# Umstieg auf „nur Tabletmodus“ stehen auf einen Schlag viele Blöcke an; ohne
# Deckel leerte das das Tageskontingent, und der Wächter könnte hängende
# Übertragungen bis zum Reset nicht mehr beenden. Höchstens
# MAX_REMOVALS_PER_DAY Entfernungen in 24 Stunden, der Rest folgt später.
#
# WELCHE ÜBERTRAGUNGEN: beendet, einem Spiel zugeordnet, Spielbericht
# `match_record_closed` oder `finalized`, Ende nicht länger als MAX_AGE her. Nach
# dem Abschluss korrigieren Admin und SBK noch, deshalb läuft es bis zum
# Freigeben und darüber hinaus bis MAX_AGE weiter. Schon beschriebene
# Aufzeichnungen werden danach unbefristet einmal täglich nachgerechnet
# (#nachzurechnen), damit eine spätere DSGVO-Anonymisierung durchschlägt. Geschrieben wird nur, wenn
# sich der Markenblock geändert hat (`chapters_digest`); der Normalfall eines
# Laufs kostet damit kein Kontingent.
#
# KONTINGENT: Start und Länge der Aufzeichnung werden einmal je Übertragung
# gelesen (`videos.list`, eine Einheit je 50 Videos) und an `stream_broadcasts`
# gespeichert. Erst ein geänderter Block kostet etwas: eine Einheit für das
# frische Lesen der Beschreibung, 50 für das Schreiben.
#
# NICHT GESCHRIEBEN wird für nachgetragene Berichte: Liegen bei mindestens
# NACHTRAG_MIN_GOALS Toren mit Eingabezeit als Anker die Eingaben im Mittel
# weniger als NACHTRAG_MEAN_GAP Sekunden auseinander, wurde der Bericht offensichtlich in einem Rutsch vom Papier
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

  # Nachgetragen: mindestens so viele Tore, und im Mittel liegen zwischen zwei
  # aufeinanderfolgenden Eingaben weniger als NACHTRAG_MEAN_GAP. Im echten
  # Spiel liegen Minuten dazwischen, beim Abtippen vom Papier Sekunden.
  NACHTRAG_MIN_GOALS = 3
  NACHTRAG_MEAN_GAP = 60

  # Wie lange nach dem Ende einer Übertragung zum ersten Mal geschrieben wird.
  # Schon beschriebene Aufzeichnungen werden danach weiter nachgerechnet,
  # einmal am Tag (RECHECK_INTERVAL), höchstens ALT_BATCH je Lauf.
  MAX_AGE = 14.days
  RECHECK_INTERVAL = 1.day
  ALT_BATCH = 100

  # Entfernte Blöcke je 24 Stunden, rund ein Fünftel des Tageskontingents.
  MAX_REMOVALS_PER_DAY = 40

  # Nach so vielen Fehlversuchen für denselben Inhalt wird aufgegeben.
  MAX_ATTEMPTS = 3

  # Die Beschreibung fasst bei YouTube 5000 Bytes, und spitze Klammern weist
  # `videos.update` ab.
  MAX_DESCRIPTION_BYTES = 5000

  attr_reader :notes, :probleme, :written

  def initialize(api:, dry_run: false, now: Time.current)
    @api = api
    @dry_run = dry_run
    @now = now
    @notes = []
    @probleme = []
    @written = []
    @removals_left = nil
  end

  def run
    saetze = kandidaten
    return self if saetze.empty?

    details_nachladen(saetze)
    saetze.each do |satz|
      verarbeite(satz)
    rescue YoutubeLiveApi::QuotaExceeded, YoutubeLiveApi::AuthError => e
      # Ein Zustand, kein Einzelfall: Jeder weitere Satz scheitert genauso.
      # Gezählt wird das nicht als Fehlversuch, sonst wären nach einem
      # widerrufenen Token alle Übertragungen als gescheitert markiert.
      problem("Sprungmarken abgebrochen (#{e.class}): #{e.message}")
      break
    end
    self
  rescue YoutubeLiveApi::QuotaExceeded, YoutubeLiveApi::AuthError => e
    problem("Sprungmarken abgebrochen (#{e.class}): #{e.message}")
    self
  end

  # Der Markenblock für ein Spiel und eine Übertragung, oder nil ohne
  # Tabletmodus oder wenn es nichts zu markieren gibt. Öffentlich, damit die Tests und ein Probelauf ihn
  # ohne YouTube sehen.
  def self.block_for(game, broadcast)
    return nil unless game.tablet_capture?

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

    (eingaben.max - eingaben.min) / (eingaben.size - 1) < NACHTRAG_MEAN_GAP
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
    geschlossen = StreamBroadcast.joins(:game).where(games: { game_status: %w[match_record_closed finalized] })
    frisch = geschlossen.where(ended_at: (@now - MAX_AGE)..@now).order(:ended_at).to_a
    frisch + nachzurechnen(geschlossen)
  end

  # Schon beschriebene Aufzeichnungen bleiben UNBEFRISTET in der Pflicht: Wird
  # ein Nachname später DSGVO-halber weggelassen, muss er auch aus der
  # Beschreibung verschwinden. Nachgerechnet wird lokal (Digest), YouTube wird
  # erst bei geändertem Block angefasst. Damit die Datenbank nicht alle fünf
  # Minuten jede je beschriebene Übertragung neu rechnet, kommt jede höchstens
  # einmal am Tag dran, höchstens ALT_BATCH je Lauf.
  #
  # Kalibrierte Aufzeichnungen (fe#560) zählen mit, auch wenn sie noch nie
  # beschrieben wurden: Erst der Versatz kann Marken in die Aufzeichnung
  # schieben. HighlightEditor setzt dazu `chapters_checked_at` zurück, damit der
  # nächste Lauf sie sofort nimmt.
  def nachzurechnen(geschlossen)
    geschlossen.where('stream_broadcasts.chapters_written_at IS NOT NULL OR stream_broadcasts.calibrated_at IS NOT NULL')
               .where(ended_at: ...(@now - MAX_AGE))
               .where('stream_broadcasts.chapters_checked_at IS NULL OR stream_broadcasts.chapters_checked_at < ?',
                      @now - RECHECK_INTERVAL)
               .order(Arel.sql('stream_broadcasts.chapters_checked_at ASC NULLS FIRST'))
               .limit(ALT_BATCH)
               .to_a
  end

  # Start und Länge für die Sätze, denen sie noch fehlen. Die Länge steht bei
  # YouTube erst nach der Verarbeitung der Aufzeichnung fest; bis dahin meldet
  # sie `P0D`, und der nächste Lauf fragt erneut.
  def details_nachladen(saetze)
    offen = saetze.reject { |satz| satz.actual_start_at.present? && satz.vod_duration_seconds.to_i.positive? }
    return if offen.empty?

    begin
      details = @api.videos(offen.map(&:broadcast_id))
    rescue YoutubeLiveApi::QuotaExceeded, YoutubeLiveApi::AuthError
      raise
    rescue YoutubeLiveApi::Error => e
      notiz("Sprungmarken: Videodaten nicht abrufbar (#{e.class}): #{e.message}")
      return
    end

    offen.each { |satz| details_speichern(satz, details[satz.broadcast_id]) }
  end

  def details_speichern(satz, werte)
    return if werte.nil?

    satz.actual_start_at = werte[:actual_start_at] if werte[:actual_start_at]
    satz.vod_duration_seconds = werte[:duration_seconds] if werte[:duration_seconds].to_i.positive?
    satz.save! if !@dry_run && satz.changed?
  rescue StandardError => e
    problem("Sprungmarken: Videodaten für #{satz.broadcast_id} nicht gespeichert: #{e.class} #{e.message}")
  end

  def verarbeite(satz)
    stempel_pruefung(satz)
    block = self.class.block_for(satz.game, satz)
    digest = block && Digest::SHA256.hexdigest(block)
    return if digest == satz.chapters_digest
    # Noch nie geschrieben und nichts zu schreiben: kein Aufruf.
    return if block.nil? && satz.chapters_written_at.nil?
    # Für genau diesen Inhalt schon endgültig gescheitert und gemeldet.
    return if satz.chapters_failed_at.present? && satz.chapters_attempt_digest == digest.to_s
    return if block.nil? && !entfernen_erlaubt?(satz)

    if @dry_run
      text = block ? "würde Sprungmarken schreiben: #{satz.broadcast_id}\n#{block}" : "würde Sprungmarken entfernen: #{satz.broadcast_id}"
      notiz("[Probelauf] #{text}")
      return
    end

    schreibe(satz, block, digest)
  rescue YoutubeLiveApi::QuotaExceeded, YoutubeLiveApi::AuthError
    raise
  rescue StandardError => e
    # Ein einzelnes Spiel (kaputter Altdatensatz, Netzfehler) darf weder die
    # übrigen Übertragungen noch den Wächter aufhalten.
    fehlversuch(satz, digest, e)
  end

  def schreibe(satz, block, digest)
    ergebnis = @api.update_description!(satz.broadcast_id) do |beschreibung|
      neu = self.class.beschreibung_mit(beschreibung, block)
      if neu.bytesize > MAX_DESCRIPTION_BYTES
        raise YoutubeLiveApi::ClientError, "Beschreibung zu lang (#{neu.bytesize} Bytes)"
      end

      neu
    end
    satz.update!(chapters_digest: digest, chapters_written_at: @now, chapters_attempts: 0,
                 chapters_attempt_digest: nil, chapters_failed_at: nil)
    @written << { broadcast_id: satz.broadcast_id, result: ergebnis, markers: block ? block.lines.size - 2 : 0 }
    notiz("Sprungmarken (#{ergebnis}): #{satz.broadcast_id}")
  end

  # Zählt Fehlversuche je Inhalt. Vorübergehende Fehler bleiben Notizen, bis
  # MAX_ATTEMPTS erreicht ist; eine 4xx-Antwort ist sofort endgültig. Gemeldet
  # wird genau einmal, beim Markieren. Ein geänderter Inhalt beginnt von vorn.
  def fehlversuch(satz, digest, fehler)
    versuche = satz.chapters_attempt_digest == digest.to_s ? satz.chapters_attempts + 1 : 1
    endgueltig = versuche >= MAX_ATTEMPTS || fehler.is_a?(YoutubeLiveApi::ClientError)
    text = "Sprungmarken für #{satz.broadcast_id}: #{fehler.class} #{fehler.message}"
    if endgueltig
      problem("#{text} -- aufgegeben nach #{versuche} Versuch(en)")
    else
      notiz("#{text} (Versuch #{versuche}, wird wiederholt)")
    end
    return if @dry_run

    satz.update_columns(chapters_attempts: versuche, chapters_attempt_digest: digest.to_s,
                        chapters_failed_at: endgueltig ? @now : nil)
  rescue StandardError => e
    problem("Sprungmarken für #{satz.broadcast_id}: Fehlversuch nicht vermerkt: #{e.class} #{e.message}")
  end

  # Zählt die in den letzten 24 Stunden entfernten Blöcke (Digest leer,
  # geschrieben) einmal je Lauf und dann lokal herunter. Ein zurückgestellter
  # Satz kommt im nächsten Lauf bzw. bei der nächsten Nachrechnung wieder dran.
  def entfernen_erlaubt?(satz)
    @removals_left ||= MAX_REMOVALS_PER_DAY -
                       StreamBroadcast.where(chapters_digest: nil, chapters_written_at: (@now - 1.day)..@now).count
    if @removals_left <= 0
      notiz("Sprungmarken: Entfernen für #{satz.broadcast_id} zurückgestellt (Tagesdeckel)")
      return false
    end

    @removals_left -= 1
    true
  end

  def stempel_pruefung(satz)
    return if @dry_run || satz.ended_at.nil? || satz.ended_at >= @now - MAX_AGE

    satz.update_columns(chapters_checked_at: @now)
  end

  def notiz(text)
    @notes << text
  end

  def problem(text)
    @notes << "PROBLEM: #{text}"
    @probleme << text unless @dry_run
  end
end
