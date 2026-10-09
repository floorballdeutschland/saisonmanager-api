# Oeffentliche Kursseite: Angebot ohne Login, Anmeldung ohne Konto.
#
# Die Liste ist bewusst ohne API-Key erreichbar: Sie ist zum Einbetten auf den
# Verbandsseiten gedacht (statische Seite unter /kurse-einbettung/), enthaelt
# nur oeffentliche Angaben und keinen Online-Link. Gedrosselt wird ueber
# Rack::Attack.
#
# Anmeldung ohne Konto (RefereeCourseRegistrar mit confirm_email):
# - Mit Lizenznummer UND passendem Geburtsdatum eines Bestandsschiris mit
#   hinterlegter Adresse geht der Bestaetigungslink an diese Adresse, nicht an
#   die eingegebene. So kann niemand fremde Schiris anmelden.
# - Sonst ist es eine neue Person. Moegliche Bestandsschiris landen als Hinweis
#   fuer die RSK an der Anmeldung (RefereeIdentityMatcher), zugeordnet wird nie
#   automatisch.
# Die Antwort ist in beiden Faellen gleich, damit sich nicht abfragen laesst,
# ob eine Lizenznummer zu einem Geburtsdatum passt.
class PublicRefereeCoursesController < ApplicationController
  skip_before_action :authenticate_user

  CONSENT_VERSION = '2026-10'.freeze

  before_action :set_course, only: %i[show register]

  # GET /api/v2/public/referee_courses?state_association_id=&course_format=&course_type=
  def index
    return render json: { enabled: false, courses: [], state_associations: [] } unless Setting.referee_courses_enabled?

    courses = offers
    courses = filter_by_state_association(courses, params[:state_association_id].to_i) if
      params[:state_association_id].present?
    courses = courses.select { |c| c.format == params[:course_format] } if params[:course_format].present?
    courses = courses.select { |c| c.course_type == params[:course_type] } if params[:course_type].present?
    levels = RefereeLicenseLevel.where(id: courses.flat_map(&:license_level_ids)).index_by(&:id)

    render json: {
      enabled: true,
      consent_version: CONSENT_VERSION,
      state_associations: StateAssociation.where(id: offers.flat_map(&:managing_state_association_ids))
                                          .order(:name).map { |sa| { id: sa.id, name: sa.name } },
      courses: courses.map { |c| c.offer_hash(levels_by_id: levels) }
    }
  end

  # GET /api/v2/public/referee_courses/clubs
  # Vereinsauswahl fuer das Anmeldeformular: aktive Vereine, nur Name und LV.
  def clubs
    list = Club.where(deactivated_at: nil).order(:name)
    render json: list.map { |c| { id: c.id, name: c.name, state_association_id: c.state_association_id } }
  end

  # GET /api/v2/public/referee_courses/:id
  def show
    render json: @course.offer_hash.merge(consent_version: CONSENT_VERSION)
  end

  # POST /api/v2/public/referee_courses/:id/registrations
  def register
    input = params.require(:registration)
    unless ActiveModel::Type::Boolean.new.cast(input[:consent])
      return render json: { error: 'Bitte der Datenverarbeitung zustimmen' }, status: :unprocessable_entity
    end

    attrs = person_attrs(input).merge(
      desired_license_level_id: input[:desired_license_level_id], remarks: input[:remarks],
      custom_answers: answers_param || {},
      consent_version: CONSENT_VERSION, consent_at: Time.current, consent_ip: request.remote_ip
    )
    result = RefereeCourseRegistrar.new(@course).register(attrs, source: 'public', confirm_email: true)
    return render json: { error: result.error }, status: :unprocessable_entity unless result.success?

    render json: { status: 'pending_email' }, status: :created
  end

  private

  def offers
    @offers ||= RefereeCourse.upcoming_offers.where(public: true)
                             .includes(:state_association, :hosting_club, :fields).ordered
                             .to_a.select(&:process_enabled?)
  end

  # Ein LV sieht seine eigenen, gemeinsam mit ihm veranstaltete und bundesweite
  # Kurse. Unterverbaende zaehlen mit (Verbandsbaum).
  def filter_by_state_association(courses, sa_id)
    ids = StateAssociation.ids_under([sa_id]) | [sa_id]
    courses.select { |c| c.national? || c.managing_state_association_ids.intersect?(ids) }
  end

  def set_course
    @course = RefereeCourse.upcoming_offers.where(public: true).find_by(id: params[:id])
    return if @course&.process_enabled?

    render json: { error: 'Kurs nicht gefunden' }, status: :not_found
  end

  def answers_param
    raw = params.dig(:registration, :custom_answers)
    return nil if raw.nil?

    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
  end

  def person_attrs(input)
    base = {
      vorname: input[:vorname], nachname: input[:nachname], geburtsdatum: input[:geburtsdatum], email: input[:email],
      telefon: input[:telefon], club_id: input[:club_id].presence, billing_address: input[:club_id].present? ? nil : input[:billing_address],
      guardian_name: input[:guardian_name], guardian_email: input[:guardian_email],
      stated_lizenznummer: input[:lizenznummer].to_s.strip.presence
    }
    referee = known_referee(base[:stated_lizenznummer], base[:geburtsdatum])
    if referee
      return base.merge(referee: referee, identity_match: 'confirmed_existing',
                        user_id: User.where(referee_id: referee.id).pick(:id),
                        vorname: referee.vorname, nachname: referee.nachname, geburtsdatum: referee.geburtsdatum,
                        email: referee.email, club_id: base[:club_id] || referee.club_id,
                        billing_address: nil)
    end

    hints = RefereeIdentityMatcher.hints(vorname: base[:vorname], nachname: base[:nachname],
                                         geburtsdatum: parse_date(base[:geburtsdatum]), email: base[:email])
    base.merge(identity_match: hints.any? ? 'needs_review' : 'new_person', match_candidates: hints)
  end

  # Nur mit Lizenznummer, passendem Geburtsdatum und hinterlegter Adresse.
  def known_referee(lizenznummer, geburtsdatum)
    return nil if lizenznummer.blank? || !lizenznummer.match?(/\A\d+\z/)

    date = parse_date(geburtsdatum)
    return nil if date.nil?

    Referee.where(merged_into_id: nil, lizenznummer: lizenznummer.to_i, geburtsdatum: date)
           .where.not(email: [nil, '']).first
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end
end
