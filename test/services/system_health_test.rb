require 'test_helper'

class SystemHealthTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    ActionMailer::Base.deliveries.clear
  end

  test 'Ampel richtet sich nach den Schwellen' do
    assert_equal 'ok', SystemHealth.status_for_percent(0)
    assert_equal 'ok', SystemHealth.status_for_percent(SystemHealth::WARNING_PERCENT - 1)
    assert_equal 'warning', SystemHealth.status_for_percent(SystemHealth::WARNING_PERCENT)
    assert_equal 'warning', SystemHealth.status_for_percent(SystemHealth::CRITICAL_PERCENT - 1)
    assert_equal 'critical', SystemHealth.status_for_percent(SystemHealth::CRITICAL_PERCENT)
    assert_equal 'unknown', SystemHealth.status_for_percent(nil)
  end

  test 'Nur eine Verschlechterung gilt als Verschlechterung' do
    assert SystemHealth::DailyCheck.worsened?('ok', 'warning')
    assert SystemHealth::DailyCheck.worsened?('warning', 'critical')
    # Erste Messung überhaupt: unbekannter Vorzustand, Warnung trotzdem sinnvoll.
    assert SystemHealth::DailyCheck.worsened?('unknown', 'critical')

    assert_not SystemHealth::DailyCheck.worsened?('warning', 'warning')
    assert_not SystemHealth::DailyCheck.worsened?('critical', 'warning')
    assert_not SystemHealth::DailyCheck.worsened?('critical', 'ok')
    # Ein fehlgeschlagenes df darf nichts auslösen.
    assert_not SystemHealth::DailyCheck.worsened?('ok', 'unknown')
  end

  test 'Restlaufzeit nur bei vorhandenem Wachstum' do
    assert_nil SystemHealth::Inventory.months_until_full(nil, 1024)
    assert_nil SystemHealth::Inventory.months_until_full(1024, 0)
    assert_nil SystemHealth::Inventory.months_until_full(1024, nil)
    assert_equal 10, SystemHealth::Inventory.months_until_full(10_240, 1024)
  end

  test 'Wachstumstabelle deckt alle Monate ab, auch die ohne Uploads' do
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new('x' * 100), filename: 'a.pdf')

    months = SystemHealth::Inventory.monthly_upload_bytes

    assert_equal SystemHealth::HISTORY_MONTHS, months.size
    assert_equal Date.current.strftime('%Y-%m'), months.last[:month]
    assert_equal 100, months.last[:total_bytes]
    assert_equal 0, months.first[:total_bytes]
  end

  test 'Taeglicher Lauf schreibt den Tageswert und warnt bei neu ueberschrittener Schwelle' do
    stub_disk_percent(SystemHealth::CRITICAL_PERCENT) do
      result = SystemHealth::DailyCheck.run!

      assert_equal 'critical', result[:status]
      assert result[:notified]
      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_equal SystemHealth::CRITICAL_PERCENT,
                   DailyMetric.find_by(metric_key: SystemHealth::DISK_METRIC_KEY, date: Date.current).count
    end
  end

  test 'Gleichbleibende Belegung loest keine zweite Mail aus' do
    DailyMetric.set!(SystemHealth::DISK_METRIC_KEY, SystemHealth::WARNING_PERCENT, Date.current - 1)

    stub_disk_percent(SystemHealth::WARNING_PERCENT) do
      result = SystemHealth::DailyCheck.run!

      assert_equal 'warning', result[:status]
      assert_equal 'warning', result[:previous_status]
      assert_not result[:notified]
      assert_empty ActionMailer::Base.deliveries
    end
  end

  test 'Von warning auf critical warnt erneut' do
    DailyMetric.set!(SystemHealth::DISK_METRIC_KEY, SystemHealth::WARNING_PERCENT, Date.current - 1)

    stub_disk_percent(SystemHealth::CRITICAL_PERCENT) do
      assert SystemHealth::DailyCheck.run![:notified]
      assert_equal 1, ActionMailer::Base.deliveries.size
    end
  end

  test 'Vergleichswert ist die letzte vorliegende Messung, nicht zwingend der Vortag' do
    DailyMetric.set!(SystemHealth::DISK_METRIC_KEY, SystemHealth::CRITICAL_PERCENT, Date.current - 5)

    stub_disk_percent(SystemHealth::CRITICAL_PERCENT) do
      result = SystemHealth::DailyCheck.run!

      # Der Job lief fünf Tage nicht. Die Lücke darf nicht als Verbesserung
      # durchgehen und erneut warnen.
      assert_equal 'critical', result[:previous_status]
      assert_not result[:notified]
    end
  end

  test 'Probelauf schreibt nichts und verschickt nichts' do
    stub_disk_percent(SystemHealth::CRITICAL_PERCENT) do
      result = SystemHealth::DailyCheck.run!(notify: false, record: false)

      assert_not result[:notified]
      assert_empty ActionMailer::Base.deliveries
      assert_nil DailyMetric.find_by(metric_key: SystemHealth::DISK_METRIC_KEY, date: Date.current)
    end
  end

  test 'Ohne lokalen Speicherdienst bleibt der Zustand unbekannt' do
    SystemHealth.stub(:uploads_path, nil) do
      disk = SystemHealth.uploads_disk

      assert_equal 'unknown', disk[:status]
      assert_equal 'no_disk_service', disk[:reason]
    end
  end

  test 'Fehlgeschlagenes df fuehrt nicht zu einer Warnung' do
    SystemHealth.stub(:disk_usage, nil) do
      result = SystemHealth::DailyCheck.run!

      assert_equal 'unknown', result[:status]
      assert_not result[:notified]
      assert_empty ActionMailer::Base.deliveries
    end
  end

  private

  # `df` liefert die echte Belegung der Testmaschine. Für die Schwellenlogik wird
  # nur der Prozentwert ersetzt, die übrige Struktur bleibt echt.
  def stub_disk_percent(percent, &block)
    total = 100 * 1024 * 1024 * 1024
    used = total * percent / 100
    usage = { total_bytes: total, used_bytes: used, free_bytes: total - used, used_percent: percent }

    SystemHealth.stub(:disk_usage, usage, &block)
  end
end
