require 'csv'

module Admin
  # Übersicht aller Beobachtungsbögen der Schiedsrichtercoaches (Feedback-Repo
  # #73). Bisher waren die Bögen nur einzeln am Schiri-Profil erreichbar
  # (RefereeObservationsController#index); wer die Coaching-Arbeit eines
  # Zeitraums sehen wollte, musste Profil für Profil aufrufen.
  #
  # Sichtbarkeit wie am Profil: RefereeObservationPolicy#admin_scope. FD-Rollen
  # sehen alle Bögen, LV-RSK und LV-Ansetzer die ihres Spielbetriebs.
  #
  # Der Export enthält bewusst nur Kopfdaten und Noten, keine Freitexte. Die
  # Texte sind die eigentliche Rückmeldung an die beobachtete Person; als
  # Massendatei würden sie das System verlassen, ohne dass jemand den
  # Zusammenhang des einzelnen Bogens sieht. Wer den Text braucht, liest den Bogen
  # in der Übersicht.
  class RefereeObservationReportsController < ApplicationController
    XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'.freeze
    STATUSES = %w[visible hidden].freeze

    before_action :authorize_view!

    # GET /api/v2/admin/referee_observation_report
    def index
      render json: {
        filters: applied_filters,
        options: filter_options,
        observations: observations.map { |o| RefereeObservationSerializer.new(o).as_json }
      }
    end

    # GET /api/v2/admin/referee_observation_report/export.(csv|xlsx)
    # Mit `ids[]` nur die ausgewählten Bögen, sonst alle zum Filter passenden.
    def export
      rows = export_scope
      respond_to do |format|
        format.csv { send_data to_csv(rows), filename: export_filename('csv'), type: 'text/csv' }
        format.xlsx { send_data to_xlsx(rows), filename: export_filename('xlsx'), type: XLSX_MIME }
      end
    end

    private

    def policy
      @policy ||= RefereeObservationPolicy.new(current_user)
    end

    def authorize_view!
      return if policy.can_view_admin?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # --- Datenbeschaffung -----------------------------------------------------

    def base_scope
      policy.admin_scope.includes(:ratings, game: [:home_team, :guest_team,
                                                   { game_day: { league: :game_operation } }])
    end

    # Saison, Spielbetrieb, Coach, Schiedsrichter und Status in SQL; das Datum in
    # Ruby, weil game_days.date eine Textspalte ist (siehe parse_date).
    def observations
      @observations ||= begin
        rel = base_scope
        rel = rel.joins(game: { game_day: :league }).where(leagues: { season_id: season_id }) if season_id
        rel = rel.where(game_operation_id: game_operation_id) if game_operation_id
        rel = rel.for_coach(coach_id) if coach_id
        rel = rel.for_referee(referee_id) if referee_id
        rel = rel.where(status: status) if status
        rel.to_a.select { |o| in_date_range?(o) }.sort_by { |o| sort_key(o) }
      end
    end

    def export_scope
      ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
      return observations if ids.empty?

      observations.select { |o| ids.include?(o.id) }
    end

    # Neueste Spiele zuerst; ohne lesbares Datum ans Ende.
    def sort_key(observation)
      date = game_date(observation)
      [date ? -date.jd : 0, -observation.submitted_at.to_i]
    end

    def in_date_range?(observation)
      return true unless from_date || to_date

      date = game_date(observation)
      return false if date.nil?
      return false if from_date && date < from_date
      return false if to_date && date > to_date

      true
    end

    def game_date(observation)
      parse_date(observation.game&.game_day&.date)
    end

    # Auswahllisten aus allen Bögen, die das Konto überhaupt sehen darf, nicht
    # nur aus den gefilterten: Sonst verschwände der gewählte Coach aus seiner
    # eigenen Auswahlliste, sobald man nach ihm filtert.
    def filter_options
      visible = policy.admin_scope
      coach_rows = visible.distinct.pluck(:coach_id, :coach_name)
      referee_rows = RefereeObservationRating.where(referee_observation_id: visible.select(:id))
                                             .distinct.pluck(:referee_id, :referee_name)
      game_operations = GameOperation.where(id: visible.distinct.select(:game_operation_id))

      {
        coaches: named_options(coach_rows),
        referees: named_options(referee_rows),
        game_operations: game_operations.map { |go| { id: go.id, name: go.name } }
                                        .sort_by { |go| go[:name].to_s }
      }
    end

    # Ein Name je Person. Die Namen sind Schnappschüsse am Bogen und können sich
    # zwischen zwei Bögen unterscheiden; dann gewinnt der zuerst gelesene.
    def named_options(rows)
      rows.uniq(&:first)
          .map { |id, name| { id: id, name: name.presence || "##{id}" } }
          .sort_by { |row| row[:name].downcase }
    end

    # --- Parameter ------------------------------------------------------------

    def season_id
      params[:season_id].presence&.to_s
    end

    def game_operation_id
      params[:game_operation_id].presence&.to_i
    end

    def coach_id
      params[:coach_id].presence&.to_i
    end

    def referee_id
      params[:referee_id].presence&.to_i
    end

    # Ohne Angabe nur sichtbare Bögen: Ein zurückgenommener Bogen ist der
    # Notausgang für eine entgleiste Rückmeldung und gehört nicht unbemerkt in
    # eine Auswertung. `all` zeigt beide.
    # Ein unbekannter Wert (Tippfehler, andere Schreibweise) fällt auf
    # `visible` zurück statt auf „kein Filter“: Sonst lieferte er still auch die
    # zurückgenommenen Bögen.
    def status
      value = params[:status].presence || 'visible'
      return nil if value == 'all'

      STATUSES.include?(value) ? value : 'visible'
    end

    def from_date
      return @from_date if defined?(@from_date)

      @from_date = parse_date(params[:from])
    end

    def to_date
      return @to_date if defined?(@to_date)

      @to_date = parse_date(params[:to])
    end

    # Strikt im Spaltenformat, damit unbrauchbarer Inhalt nicht stillschweigend
    # als heute durchgeht (wie RefereeObservationPolicy#game_date).
    def parse_date(value)
      return nil if value.blank?

      Date.strptime(value.to_s, '%Y-%m-%d')
    rescue ArgumentError, TypeError
      nil
    end

    def applied_filters
      {
        season_id: season_id,
        game_operation_id: game_operation_id,
        coach_id: coach_id,
        referee_id: referee_id,
        status: status || 'all',
        from: from_date&.iso8601,
        to: to_date&.iso8601
      }
    end

    # --- Export ---------------------------------------------------------------

    DIMENSION_LABELS = {
      stick_play: 'Stocklinie',
      physical_play: 'Körperspiellinie',
      penalty_line: 'Strafenlinie',
      game_management: 'Spielleitung',
      overall: 'Gesamt'
    }.freeze

    def export_headers
      ['Datum', 'Spielnummer', 'Liga', 'Spielbetrieb', 'Heim', 'Gast', 'Coach', 'Angesetzt',
       'Status', 'Abgegeben am'] +
        rated_headers('Schiedsrichter 1') + rated_headers('Schiedsrichter 2') +
        RefereeObservation::DIMENSIONS.map { |d| "Gespann #{DIMENSION_LABELS.fetch(d)}" }
    end

    def rated_headers(label)
      [label] + RefereeObservation::DIMENSIONS.map { |d| "#{label} #{DIMENSION_LABELS.fetch(d)}" }
    end

    def export_row(observation)
      game = observation.game
      league = game&.league
      [
        game&.game_day&.date, game&.game_number, league&.name, league&.game_operation&.name,
        game&.home_team&.name, game&.guest_team&.name, observation.coach_name,
        observation.referee_assignment_id.present? ? 'ja' : 'nein',
        observation.visible? ? 'sichtbar' : 'zurückgenommen',
        observation.submitted_at&.in_time_zone('Europe/Berlin')&.strftime('%Y-%m-%d %H:%M')
      ] + rated_cells(observation, 1) + rated_cells(observation, 2) +
        RefereeObservation::PAIR_RATING_ATTRIBUTES.map { |field| observation[field] }
    end

    # Feste Spalten je Slot im Gespann, damit eine Tabelle über viele Bögen
    # spaltenweise auswertbar bleibt. Ein Bogen mit nur einer bewerteten Person
    # lässt den zweiten Block leer.
    def rated_cells(observation, position)
      rating = observation.ratings.find { |r| r.position == position }
      return Array.new(RefereeObservation::DIMENSIONS.size + 1) if rating.nil?

      [rating.referee_name] + RefereeObservationRating::RATING_ATTRIBUTES.map { |field| rating[field] }
    end

    def to_csv(rows)
      CSV.generate(headers: true) do |csv|
        csv << export_headers
        rows.each { |o| csv << export_row(o).map { |value| csv_cell(value) } }
      end
    end

    # Entschärft Zellen, die eine Tabellenkalkulation als Formel läse (Team-,
    # Coach- und Schiri-Namen; Teamnamen pflegen die Vereine selbst).
    # Wie LeaguesController#schedule_export_csv_cell; die xlsx-Fassung erledigt
    # caxlsx von sich aus (escape_formulas).
    def csv_cell(value)
      return value unless value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/)

      "'#{value}"
    end

    def to_xlsx(rows)
      package = Axlsx::Package.new
      package.workbook.add_worksheet(name: 'Beobachtungen') do |sheet|
        sheet.add_row export_headers
        rows.each { |o| sheet.add_row export_row(o), types: export_types }
      end
      package.to_stream.read
    end

    # Datum, Spielnummer und Zeitstempel als Text, sonst macht Excel aus
    # „2026-10-04" eine Formel oder schneidet führende Nullen der Spielnummer ab.
    def export_types
      @export_types ||= export_headers.each_index.map { |i| i < 10 ? :string : nil }
    end

    def export_filename(extension)
      "schiri-beobachtungen.#{extension}"
    end
  end
end
