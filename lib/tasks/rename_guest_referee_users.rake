# frozen_string_literal: true

# Stellt die Benutzernamen bestehender Gastschiedsrichter-Konten auf das Schema
# `sr-nachname` um (RefereeAccountCreator.user_name_for) und meldet jeder
# betroffenen Person den neuen Namen — auf Englisch, siehe
# UserMailer#username_changed.
#
# Bewusst ein Rake-Lauf und keine Datenmigration: Die Umbenennung sperrt die
# Person aus ihrem alten Login aus, die Mail gehört also unmittelbar dazu. Ein
# Deploy darf so etwas nicht nebenbei auslösen.
#
# Der Lauf ist idempotent: Ein Konto, das den Zielnamen schon trägt, wird
# übersprungen und bekommt keine zweite Mail.
#
# Vorschau ohne Umbenennung und ohne Versand:
#   docker exec -e DRY_RUN=1 saisonmanager_rails_api bundle exec rake referees:rename_guest_users RAILS_ENV=production
#
# Scharf:
#   docker exec saisonmanager_rails_api bundle exec rake referees:rename_guest_users RAILS_ENV=production
namespace :referees do
  desc 'Benutzernamen der Gastschiedsrichter auf sr-nachname umstellen und die Betroffenen benachrichtigen'
  task rename_guest_users: :environment do
    dry_run = ENV['DRY_RUN'].present?
    users = User.where(referee_id: Referee.where(guest: true).select(:id)).order(:id)

    puts "Gastkonten: #{users.count}#{dry_run ? ' (DRY RUN)' : ''}"

    renamed = 0
    unchanged = 0
    failed = 0
    mailed = 0
    planned = []

    users.each do |user|
      referee = Referee.find_by(id: user.referee_id)
      target = RefereeAccountCreator.user_name_for(referee, ignore_user_id: user.id)

      if target.casecmp?(user.user_name)
        unchanged += 1
        puts "  #{user.id} #{user.user_name}: unverändert"
        next
      end

      # Im Trockenlauf wird nichts gespeichert, die Kollisionsprüfung sieht die
      # vorherigen Zielnamen also nicht. Zwei Gäste gleichen Nachnamens fielen
      # hier sonst unbemerkt auf denselben Namen; scharf bekäme der zweite
      # korrekt die Ziffer.
      if dry_run && planned.any? { |name| name.casecmp?(target) }
        puts "  #{user.id} #{user.user_name} → #{target}  ACHTUNG: Name doppelt geplant, " \
             'im scharfen Lauf bekommt der zweite eine Ziffer'
      else
        puts "  #{user.id} #{user.user_name} → #{target}"
      end
      planned << target

      next if dry_run

      previous_user_name = user.user_name
      unless user.update(user_name: target)
        failed += 1
        puts "    FEHLER: #{user.errors.full_messages.to_sentence}"
        next
      end

      renamed += 1
      mailed += 1 if send_username_changed(user, previous_user_name)
    end

    if dry_run
      puts "Vorschau: #{planned.size} Umbenennung(en), #{unchanged} unverändert. " \
           'Nichts gespeichert, nichts versendet.'
    else
      puts "Fertig: #{renamed} umbenannt, #{mailed} Mail(s) versendet, " \
           "#{unchanged} unverändert, #{failed} fehlgeschlagen."
    end
  end

  # deliver_now, weil ein Rake-Prozess endet, bevor der ActiveJob-Threadpool
  # (:async, ohne Persistenz) die eingereihten Mails zustellt.
  #
  # Ein Fehlschlag beim Versand nimmt die Umbenennung nicht zurück: Der Name ist
  # gesetzt, und wer die Mail nicht bekommt, kommt über „Benutzername vergessen"
  # an ihn heran.
  def send_username_changed(user, previous_user_name)
    if user.email.blank?
      puts '    keine E-Mail-Adresse hinterlegt, keine Benachrichtigung'
      return false
    end

    UserMailer.username_changed(user, previous_user_name).deliver_now
    true
  rescue StandardError => e
    puts "    Mail fehlgeschlagen: #{e.message}"
    false
  end
end
