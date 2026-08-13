# Frühwarnung zum Betriebszustand des Servers. Verschickt ausschließlich der
# tägliche Job (lib/tasks/system_health.rake) und nur dann, wenn sich der Zustand
# gegenüber der letzten Messung verschlechtert hat.
class SystemHealthMailer < ApplicationMailer
  # Postfach, das die Warnungen sichtet. Über ENV überschreibbar, damit Staging
  # nicht ins Produktiv-Postfach schreibt.
  NOTIFY_EMAIL = ENV.fetch('SYSTEM_HEALTH_NOTIFY_EMAIL', 'it@floorball.de').freeze

  def threshold_warning(disk)
    @disk = disk
    @thresholds = { warning: SystemHealth::WARNING_PERCENT, critical: SystemHealth::CRITICAL_PERCENT }
    @growth = SystemHealth::Inventory.growth(disk[:free_bytes])

    templated_mail(
      to: NOTIFY_EMAIL,
      placeholders: {
        used_percent: disk[:used_percent].to_s,
        free_space: MailerHelper.format_bytes(disk[:free_bytes]),
        status: disk[:status].to_s
      }
    )
  end
end
