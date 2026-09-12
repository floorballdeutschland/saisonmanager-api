module LeagueBanner
  extend ActiveSupport::Concern

  included do
    has_one_attached :banner
  end

  def banner_url
    # Proxy- statt Redirect-Route: stabile URL, die der Browser behalten kann.
    # Ausfuehrliche Begruendung in app/models/concerns/league_logo.rb.
    Rails.application.routes.url_helpers.rails_storage_proxy_path(banner, only_path: true) if banner.attached?
  end

  def resolved_banner
    return { banner_url: banner_url, banner_link_url: banner_link_url } if banner.attached?

    sa = game_operation&.state_association
    return { banner_url: sa.banner_url, banner_link_url: sa.banner_link_url } if sa&.banner&.attached?

    go = game_operation
    return { banner_url: go.banner_url, banner_link_url: go.banner_link_url } if go&.banner&.attached?

    {}
  end
end
