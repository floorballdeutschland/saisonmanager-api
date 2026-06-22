class RefereeGameDayConfirmationsController < ApplicationController
  before_action :authenticate_user
  before_action :require_referee_account

  AUTO_CONFIRM_HOURS = 48

  # GET /api/v2/referee/game_days
  def index
    # Schritt 1: gefilterte Spieltag-IDs über den Assignment-Join ermitteln.
    # Getrennt von der Präsentations-Query, da SELECT DISTINCT + ORDER BY auf
    # einer nicht-selektierten Spalte (game_days.date) in Postgres scheitert.
    game_day_ids = GameDay
                   .joins(games: :referee_assignment)
                   .where(
                     'referee_assignments.status = :status AND (referee_assignments.referee1_id = :id OR referee_assignments.referee2_id = :id)',
                     status: 'published', id: @referee.id
                   )
                   .where("TO_DATE(game_days.date, 'YYYY-MM-DD') >= ?", 60.days.ago.to_date)
                   .distinct
                   .pluck(:id)

    game_days = GameDay
                .where(id: game_day_ids)
                .includes(
                  :arena, :club,
                  games: %i[home_team guest_team referee_assignment],
                  league: { game_operation: { state_association: :checklist_items } }
                )
                .order('game_days.date DESC')

    confirmations = GameDayRefereeConfirmation
                    .where(game_day_id: game_day_ids)
                    .group_by(&:game_day_id)

    render json: game_days.map { |gd| game_day_json(gd, confirmations[gd.id] || []) }
  end

  # POST /api/v2/referee/game_days/:game_day_id/confirm
  def confirm
    game_day = GameDay.find(params[:game_day_id])

    unless assigned_and_published?(game_day)
      return render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Idempotent: bereits abgegebene Bewertung unverändert zurückgeben, bevor
    # weitere Vorbedingungen (Checkliste/Zeitfenster) greifen.
    existing = GameDayRefereeConfirmation.find_by(game_day: game_day, referee: @referee)
    return render json: confirmation_payload(existing) if existing

    items = checklist_items_for(game_day)
    if items.empty?
      return render json: { error: 'Für diesen Spieltag ist keine Checkliste hinterlegt.' },
                    status: :unprocessable_entity
    end

    # properly_conducted muss explizit als Boolean angegeben werden – sonst würde
    # eine Meldung mit fehlendem Flag still als "ordnungsgemäß" gespeichert.
    properly = params[:properly_conducted]
    unless [true, false].include?(properly)
      return render json: { error: 'Angabe ordnungsgemäß (true/false) erforderlich.' },
                    status: :unprocessable_entity
    end

    threshold = last_game_start(game_day)
    if threshold && Time.current < threshold
      return render json: { error: 'Bewertung erst ab Beginn des letzten Spiels möglich.' },
                    status: :unprocessable_entity
    end

    if auto_confirmed?(game_day)
      return render json: { error: 'Spieltag wurde automatisch bestätigt', auto_confirmed: true },
                    status: :unprocessable_entity
    end

    # Bei "nicht ordnungsgemäß" muss die Checkliste vollständig mit Ja/Nein beantwortet sein.
    answers = []
    unless properly
      answers = normalize_answers(params[:answers], items)
      if answers.nil?
        return render json: { error: 'Bitte alle Checklisten-Fragen mit Ja/Nein beantworten.' },
                      status: :unprocessable_entity
      end
    end

    confirmation = GameDayRefereeConfirmation.create!(
      game_day: game_day,
      referee: @referee,
      confirmed_at: Time.current,
      properly_conducted: properly,
      checklist_answers: answers
    )

    notify_sbk_of_veto(game_day, confirmation) unless properly

    render json: confirmation_payload(confirmation), status: :created
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue ActiveRecord::RecordNotUnique
    existing = GameDayRefereeConfirmation.find_by(game_day: game_day, referee: @referee)
    render json: confirmation_payload(existing) if existing
  end

  private

  def require_referee_account
    @referee = current_user.referee
    return render json: { error: 'Kein Schiedsrichter-Profil verknüpft' }, status: :forbidden if @referee.nil?
  end

  def assigned_and_published?(game_day)
    game_day.games
            .joins(:referee_assignment)
            .where(
              'referee_assignments.status = ? AND (referee_assignments.referee1_id = ? OR referee_assignments.referee2_id = ?)',
              'published', @referee.id, @referee.id
            )
            .exists?
  end

  # Beginn des letzten Spiels eines Spieltags (spätester Anpfiff in Europe/Berlin).
  # Bestätigung ist erst ab diesem Zeitpunkt möglich. nil, wenn keine Startzeit
  # ermittelbar ist (dann keine zeitliche Sperre).
  def last_game_start(game_day)
    return nil if game_day.date.blank?

    tz = ActiveSupport::TimeZone['Europe/Berlin']
    game_day.games.filter_map do |g|
      next if g.start_time.blank?

      tz.parse("#{game_day.date} #{g.start_time}")
    rescue ArgumentError, TypeError
      nil
    end.max
  end

  def auto_confirmed?(game_day)
    return false if game_day.date.blank?

    date = Date.parse(game_day.date)
    date.to_datetime.end_of_day + AUTO_CONFIRM_HOURS.hours < Time.current
  rescue ArgumentError, TypeError => e
    Rails.logger.error(
      "[RefereeGameDayConfirmations] auto_confirmed? failed for game_day_id=#{game_day.id} " \
      "date=#{game_day.date.inspect}: #{e.class}: #{e.message}"
    )
    false
  end

  # Spieltagscheckliste des LV der Liga/des Sportverbunds (nicht des Ausrichtervereins).
  def checklist_items_for(game_day)
    game_day.league&.game_operation&.state_association&.checklist_items&.to_a || []
  end

  # Normalisiert die eingereichten Antworten gegen die Checklisten-Items.
  # nil, wenn nicht jede Frage eindeutig mit true/false beantwortet wurde.
  def normalize_answers(raw, items)
    return nil unless raw.respond_to?(:each)

    by_id = {}
    raw.each do |a|
      id = (a[:item_id] || a['item_id']).to_i
      by_id[id] = a.key?(:answer) ? a[:answer] : a['answer']
    end

    answers = items.map do |item|
      { 'item_id' => item.id, 'question' => item.question, 'answer' => by_id[item.id] }
    end
    return nil unless answers.all? { |a| [true, false].include?(a['answer']) }

    answers
  end

  def confirmation_payload(confirmation)
    {
      confirmed_at: confirmation.confirmed_at.iso8601,
      properly_conducted: confirmation.properly_conducted,
      checklist_answers: confirmation.checklist_answers
    }
  end

  # Benachrichtigt die SBK des LV, wenn ein Spieltag als nicht ordnungsgemäß
  # gemeldet wurde. Fehler hier dürfen die Antwort nicht scheitern lassen.
  def notify_sbk_of_veto(game_day, confirmation)
    sa = game_day.league&.game_operation&.state_association
    return if sa&.sbk_email.blank?

    GameDayMailer.referee_checklist_veto(game_day, @referee, confirmation.checklist_answers, sa).deliver_later
  rescue StandardError => e
    Rails.logger.warn("notify_sbk_of_veto failed for game_day_id=#{game_day.id}: #{e.class}: #{e.message}")
  end

  def game_day_json(game_day, day_confirmations)
    published_assignments = game_day.games
                                    .filter_map(&:referee_assignment)
                                    .select { |a| a.status == 'published' && (a.referee1_id == @referee.id || a.referee2_id == @referee.id) }

    partner_id = published_assignments
                 .filter_map { |a| a.referee1_id == @referee.id ? a.referee2_id : a.referee1_id }
                 .compact
                 .first

    # Nur die Spiele auflisten, auf die der Schiri tatsächlich (veröffentlicht)
    # angesetzt ist – nicht alle Spiele des Spieltags. Sonst tauchten z. B.
    # frühere Parallelspiele in derselben Halle fälschlich in „Meine Spieltage" auf.
    assigned_game_ids = published_assignments.map(&:game_id).to_set

    my_confirmation = day_confirmations.find { |c| c.referee_id == @referee.id }
    partner_confirmation = partner_id ? day_confirmations.find { |c| c.referee_id == partner_id } : nil
    auto_conf = auto_confirmed?(game_day)
    items = checklist_items_for(game_day)

    {
      id: game_day.id,
      date: game_day.date,
      league: game_day.league&.name,
      arena: game_day.arena&.name,
      club: game_day.club&.name,
      my_confirmed_at: my_confirmation&.confirmed_at&.iso8601,
      partner_confirmed_at: partner_confirmation&.confirmed_at&.iso8601,
      auto_confirmed: auto_conf,
      confirmable_from: last_game_start(game_day)&.iso8601,
      # Bestätigung nur nötig, wenn der LV der Liga eine Checkliste hinterlegt hat.
      checklist_required: items.any?,
      checklist_items: items.map { |i| { id: i.id, question: i.question } },
      properly_conducted: my_confirmation&.properly_conducted,
      my_checklist_answers: my_confirmation&.checklist_answers || [],
      partner_properly_conducted: partner_confirmation&.properly_conducted,
      games: game_day.games
                     .select { |g| assigned_game_ids.include?(g.id) }
                     .sort_by { |g| g.start_time || '' }
                     .map do |g|
               {
                 id: g.id,
                 game_number: g.game_number,
                 start_time: g.start_time,
                 home_team: g.home_team&.name,
                 guest_team: g.guest_team&.name,
                 result: g.result_string
               }
             end
    }
  end
end
