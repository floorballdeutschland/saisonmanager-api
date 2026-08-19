FROM ruby:3.2.4

# Bookworm-Basis bleiben lassen: ActiveStorage >= 7.2 wirft BEIM BOOTEN einen
# RuntimeError, wenn libvips < 8.13 oder ruby-vips < 2.2.1 ist (Korrektur der
# kritischen Meldung GHSA-xr9x-r78c-5hrm). Bookworm liefert libvips 8.14,
# ruby-vips steht im Gemfile.lock auf 2.2.2 — beides ausreichend.
#
# Achtung bei einem Wechsel auf ruby:3.2.4-bullseye: Bullseye liefert libvips
# 8.10, die API startet dann nicht mehr. Das ist relevant, weil bei
# clone3/seccomp-Problemen auf aelteren Docker-Hosts sonst genau dieses Image
# das naheliegende Ausweichquartier ist.
RUN apt-get update -qq && apt-get install -y nodejs postgresql-client libvips42

ENV RAILS_ROOT /app
RUN mkdir -p $RAILS_ROOT

WORKDIR $RAILS_ROOT

# Gems:
COPY Gemfile Gemfile
COPY Gemfile.lock Gemfile.lock
RUN bundle install

RUN echo "source ~/.aliases" >> ~/.bashrc


COPY . /app

EXPOSE 3000

CMD ["rails", "server", "-b", "0.0.0.0"]
