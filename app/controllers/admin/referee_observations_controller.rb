module Admin
  # Beobachtungsbögen in der Schiedsrichterverwaltung: am Schiri-Profil lesen und
  # im Notfall zurücknehmen.
  #
  # Anders als beim Vereins-Feedback ist die Sicht nicht auf die global gescopten
  # FD-Rollen begrenzt. Ein Landesverband, der selbst coacht, muss die eigenen
  # Bögen sehen; begrenzt wird deshalb nicht die Rolle, sondern über
  # RefereeObservationPolicy#admin_scope der Spielbetrieb.
  #
  # Beide Endpunkte lesen ausschließlich aus den Rollen-Scopes der Policy und nie
  # aus deren persönlicher Sicht: Diese Maske zeigt den vollständigen Bogen samt
  # der Noten beider Gespannmitglieder, und Statusänderungen sind ein Eingriff in
  # eine Rückmeldung über eine andere Person. Beides darf nicht daran hängen,
  # dass das Konto in dem Bogen selbst vorkommt.
  class RefereeObservationsController < ApplicationController
    before_action :authenticate_user

    # GET /api/v2/admin/referees/:referee_id/observations
    # Bögen, in denen diese Person bewertet wurde – vollständig, also inklusive
    # der Bewertungen des Gespannpartners. Die Verwaltung braucht den ganzen
    # Bogen, um ihn einordnen zu können; die betroffene Person selbst sieht in
    # ihrem Profil nur ihre eigenen Zeilen.
    def index
      return forbidden unless policy.can_view_admin?

      referee = Referee.find(params[:referee_id])
      observations = policy.admin_scope
                           .for_referee(referee.id)
                           .includes(:ratings, game: { game_day: { league: :game_operation } })
                           .order(submitted_at: :desc)

      render json: {
        summary: summary(observations.select(&:visible?), referee.id),
        observations: observations.map { |o| RefereeObservationSerializer.new(o).as_json }
      }
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    # PATCH /api/v2/admin/referee_observations/:id
    # Nur der Status. Inhalte bleiben unveränderlich – eine nachträglich
    # umgeschriebene Rückmeldung wäre für die beobachtete Person nicht mehr
    # nachvollziehbar.
    def update
      return forbidden unless policy.can_moderate?

      status = params[:status].to_s
      return render json: { error: 'Ungültiger Status' }, status: :unprocessable_entity unless
        %w[visible hidden].include?(status)

      observation = policy.moderation_scope.find(params[:id])
      observation.update!(status: status)
      head :no_content
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    private

    def policy
      @policy ||= RefereeObservationPolicy.new(current_user)
    end

    def forbidden
      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Mittelwerte über die Einzelbewertungen DIESER Person, nicht über die des
    # Gespanns: Genau dafür gibt es die Kindtabelle. Ohne Bögen bleibt der Schnitt
    # nil statt 0, damit die Oberfläche „keine Daten" von „schlecht" unterscheidet.
    def summary(observations, referee_id)
      ratings = observations.flat_map(&:ratings).select { |r| r.referee_id == referee_id }
      averages = RefereeObservationRating::RATING_ATTRIBUTES.index_with do |field|
        values = ratings.filter_map { |r| r[field] }
        values.any? ? (values.sum.to_f / values.size).round(1) : nil
      end
      { count: observations.size }.merge(averages)
    end
  end
end
