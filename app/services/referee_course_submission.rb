# Die RSK reicht die Ergebnisse eines durchgefuehrten Kurses an FD ein.
#
# Die Lizenz legt immer FD fest (Entscheidung 09.10.2026): Aus jeder
# bestandenen Teilnahme entsteht eine Ergebniszeile ohne Lizenzstufe, die
# FD-RSK in der Lizenzvergabe pruefen, mit Stufe versehen und erteilen oder
# mit Begruendung ablehnen (Admin::RefereeCourseLicensingController). Der LV
# macht keinen Vorschlag; die angestrebte Stufe der Person bleibt ein Hinweis.
#
# Vorher muss die Teilnehmerliste fertig sein: jede Anmeldung mit Platz hat
# eine Anwesenheit, jede Teilnahme ein Ergebnis, und jeder Hinweis auf einen
# moeglichen Bestandsschiri ist geklaert.
class RefereeCourseSubmission
  Result = Struct.new(:results, :errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  def initialize(course, submitted_by:)
    @course = course
    @submitted_by = submitted_by
  end

  def problems
    errors = []
    errors << 'Der Kurs muss als durchgeführt markiert sein' unless @course.status == 'held'
    seated = @course.registrations.where(status: RefereeCourseRegistration::SEAT_STATUSES).to_a
    open_attendance = seated.select { |r| r.status == 'registered' }
    errors << "Anwesenheit fehlt bei: #{names(open_attendance)}" if open_attendance.any?
    no_result = seated.select { |r| r.status == 'attended' && r.result.nil? }
    errors << "Ergebnis fehlt bei: #{names(no_result)}" if no_result.any?
    unresolved = seated.select { |r| r.identity_match == 'needs_review' && r.referee_id.nil? }
    errors << "Zuordnung ungeklärt bei: #{names(unresolved)}" if unresolved.any?
    errors
  end

  def call
    errors = problems
    return Result.new(results: [], errors: errors) if errors.any?

    results = []
    RefereeCourse.transaction do
      @course.lock!
      # Nach der Sperre erneut pruefen: Ein Doppelklick oder zwei parallele
      # Aufrufe sahen beide noch `held` und legten jede Ergebniszeile doppelt an.
      unless @course.status == 'held'
        return Result.new(results: [], errors: ['Der Kurs ist bereits eingereicht'])
      end

      @course.registrations.where(status: 'attended', result: 'passed').includes(:referee, :club).find_each do |reg|
        results << RefereeCourseResult.create!(result_attrs(reg))
      end
      @course.update!(status: 'results_submitted')
    end
    Result.new(results: results, errors: [])
  rescue ActiveRecord::RecordInvalid => e
    Result.new(results: [], errors: [e.record.errors.full_messages.to_sentence])
  rescue ActiveRecord::RecordNotUnique
    Result.new(results: [], errors: ['Für diesen Kurs gibt es schon eingereichte Ergebnisse'])
  end

  private

  def names(registrations)
    registrations.first(5).map { |r| "#{r.vorname} #{r.nachname}" }.join(', ') +
      (registrations.size > 5 ? " und #{registrations.size - 5} weitere" : '')
  end

  # Bestandsschiri: Stammdaten bleiben, wie sie beim Schiri stehen (der
  # Applier schreibt die finalen Werte zurueck, ein veralteter Schnappschuss
  # der Anmeldung soll nichts ueberschreiben). Neue Person: Daten aus der
  # Anmeldung.
  def result_attrs(reg)
    referee = reg.referee
    master = master_values(reg, referee)
    {
      referee_course: @course,
      referee_course_registration: reg,
      referee: referee,
      state_association_id: @course.state_association_id || reg.club&.state_association_id,
      status: 'pending_review',
      submitted_at: Time.current,
      match_type: referee ? 'exact_match' : 'new_entry',
      match_field_count: referee ? 6 : 0,
      kursstichtag: @course.ends_on || @course.starts_on,
      csv_lizenznummer: reg.stated_lizenznummer.to_s[/\A\d+\z/]&.to_i,
      csv_vorname: reg.vorname,
      csv_nachname: reg.nachname,
      csv_geburtsdatum: reg.geburtsdatum,
      csv_verein: reg.club&.name,
      csv_email: reg.email,
      course_data: course_data(reg)
    }.merge(master.transform_keys { |k| :"master_#{k}_final" })
      .merge(master.transform_keys { |k| :"master_#{k}_by_importer" })
  end

  def master_values(reg, referee)
    if referee
      { lizenznummer: referee.lizenznummer, vorname: referee.vorname, nachname: referee.nachname,
        geburtsdatum: referee.geburtsdatum, email: referee.email, club_id: referee.club_id }
    else
      { lizenznummer: nil, vorname: reg.vorname, nachname: reg.nachname,
        geburtsdatum: reg.geburtsdatum, email: reg.email, club_id: reg.club_id }
    end
  end

  # Dieselbe Form wie beim CSV-Import, damit die Kurshistorie am Profil
  # unveraendert funktioniert. Kurs 1 traegt den Kurstyp, die Kursleitung
  # ersetzt den Freitext „Ausbilder".
  def course_data(reg)
    {
      'kurs_1' => {
        'stufe' => @course.course_type.upcase,
        'datum' => (@course.ends_on || @course.starts_on)&.iso8601,
        'testversion' => reg.test_version,
        'punkte' => reg.points&.to_f
      },
      'ausbilder' => @course.lead_users.map { |u| u.fullname.strip.presence || u.user_name }.join(', ').presence,
      'kurs' => @course.title,
      'referee_course_id' => @course.id
    }
  end
end
