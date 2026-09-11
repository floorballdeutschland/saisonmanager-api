# Be sure to restart your server when you modify this file.

# Avoid CORS issues when API is called from the frontend app.
# Handle Cross-Origin Resource Sharing (CORS) in order to accept cross-origin AJAX requests.

# Read more: https://github.com/cyu/rack-cors

# Rails.application.config.middleware.insert_before 0, Rack::Cors do
#   allow do
#     origins "example.com"
#
#     resource "*",
#       headers: :any,
#       methods: [:get, :post, :put, :patch, :delete, :options, :head]
#   end
# end

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # saisonmanager.org ist raus: Die Domain leitet dauerhaft (301) auf .de um --
    # Stand 11.09.2026, nachgesehen in saisonmanager-docker,
    # nginx/config/saisonmanager.prod.conf (`server_name saisonmanager.org`).
    # Dort laeuft also keine Seite mehr, die als Herkunft auftreten koennte.
    # Wird der Redirect je zurueckgenommen, faellt das hier nicht auf: Kein Test
    # prueft eine fremde Konfiguration, der Browser meldet nur CORS.
    origins 'https://saisonmanager.de', 'https://sr.floorball.de',
            'http://localhost:4200'

    resource '*',
             headers: :any,
             credentials: true,
             expose: %w[access-token expiry token-type uid client],
             methods: %i[get post put patch delete options head]
  end
end
